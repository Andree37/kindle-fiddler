//! noface: a fast reader with its own home screen.
//! Usage: noface <library.tsv> <body.ttf> <title.ttf> <ui.ttf> <ui-bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Tapping the top of a page opens the toolbar. Dragging down from the top opens
//! the quick panel, in a book or in the library.
//! The power button locks, showing the current book's cover. Waking returns to the
//! same place. All Settings leaves for the stock UI.
const std = @import("std");
const Fonts = @import("ui/fonts.zig").Fonts;
const file = @import("linux/file.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const library = @import("ui/library.zig");
const clock = @import("linux/clock.zig");
const text = @import("layout/text.zig");
const input_mod = @import("kindle/input.zig");
const app = @import("app.zig");
const library_screen = @import("screens/library.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 7) return error.Usage;
    const alloc = std.heap.page_allocator;

    const state_dir = std.mem.sliceTo(argv[6], 0);

    const regular = try file.map(argv[2]);
    const book_bold = try file.map(argv[3]);
    const ui_regular = try file.map(argv[4]);
    const ui_bold = try file.map(argv[5]);
    var screen = try hwtcon.Screen.open();
    var fallback_body = try text.Font.init(alloc, regular, 46, 1.35);
    var note_font = try text.Font.init(alloc, regular, 36, 1.3);
    var footer = try text.Font.init(alloc, regular, 28, 1.2);
    var title = try text.Font.init(alloc, ui_bold, 34, 1.2);
    var small = try text.Font.init(alloc, ui_regular, 34, 1.2);
    var caption = try text.Font.init(alloc, ui_regular, 26, 1.2);
    var hero = try text.Font.init(alloc, book_bold, 56, 1.2);
    var cover_type = try text.Font.init(alloc, book_bold, 36, 1.2);

    var slots: [3]app.Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, screen.pixels.len) };

    var input = try input_mod.open(screen.width, screen.height);
    defer input_mod.release(&input);

    input_mod.installSignals();
    const saved_screen = try alloc.alloc(u8, screen.pixels.len);
    @memcpy(saved_screen, screen.pixels);
    defer {
        @memcpy(screen.pixels, saved_screen);
        if (screen.update(.gc16, .full)) |m| {
            screen.waitComplete(m) catch {};
        } else |_| {}
    }

    var settings_buf: [320]u8 = undefined;
    const settings_path = try std.fmt.bufPrintSentinel(&settings_buf, "{s}/settings", .{state_dir}, 0);
    var speed_buf: [320]u8 = undefined;
    const speed_path = try std.fmt.bufPrintSentinel(&speed_buf, "{s}/speed", .{state_dir}, 0);
    const ui = Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type };

    var shared = app.App{
        .alloc = alloc,
        .screen = &screen,
        .input = &input,
        .body = &fallback_body,
        .note_font = &note_font,
        .footer = &footer,
        .ui = ui,
        .slots = slots,
        .overlay = try alloc.alloc(u8, screen.pixels.len),
        .lock_saved = try alloc.alloc(u8, screen.pixels.len),
        .lock_cover = try alloc.alloc(u8, screen.pixels.len),
        .state_dir = state_dir,
        .library_path = argv[1],
        .settings_path = settings_path,
        .speed_path = speed_path,
        .speed = app.loadSpeed(speed_path),
        .utc_offset = clock.utcOffset(),
        .settings = app.loadSettings(settings_path),
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &footer },
    };
    shared.applySettings() catch {
        shared.settings = .{};
        try shared.applySettings();
    };
    try library_screen.runLibrary(&shared);
    std.debug.print("quit\n", .{});
}
