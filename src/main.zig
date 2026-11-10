//! noface: a fast reader with its own home screen.
//! Usage: noface <library.tsv> <body.ttf> <title.ttf> <ui.ttf> <ui-bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Tapping the top of a page opens the toolbar. Dragging down from the top opens
//! the quick panel, in a book or in the library.
//! The power button locks, showing the current book's cover. Waking returns to the
//! same place. The panel's Kindle button and Wi-Fi settings hand over to the stock UI.
const std = @import("std");
const memory = @import("base/memory.zig");
const c_memory = @import("gfx/c_memory.zig");
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const file = @import("linux/file.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const library = @import("ui/library.zig");
const clock = @import("linux/clock.zig");
const input_mod = @import("kindle/input.zig");
const app = @import("app.zig");
const library_screen = @import("screens/library.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 7) return error.Usage;
    // Everything that lives as long as the app: screen buffers, fonts, picture cache.
    var app_budget = memory.Budget{ .name = "app", .child = std.heap.smp_allocator, .limit = 96 << 20 };
    const alloc = app_budget.allocator();
    // Glyph bitmaps and decoded pictures from the stb C libraries.
    var stb_budget = memory.Budget{ .name = "stb", .child = std.heap.smp_allocator, .limit = 128 << 20 };
    c_memory.use(&stb_budget);

    const state_dir = std.mem.sliceTo(argv[6], 0);

    const regular = try file.map(argv[2]);
    const book_bold = try file.map(argv[3]);
    const ui_regular = try file.map(argv[4]);
    const ui_bold = try file.map(argv[5]);
    var screen = try hwtcon.Screen.open();
    var fallback_body = try Font.init(alloc, regular, 46, 1.35);
    var note_font = try Font.init(alloc, regular, 36, 1.3);
    var footer = try Font.init(alloc, ui_regular, 28, 1.2); // Under the page: interface text
    var reference = try Font.init(alloc, regular, 28, 1.2); // Note marks in the text: the book's own face
    var title = try Font.init(alloc, ui_bold, 34, 1.2);
    var small = try Font.init(alloc, ui_regular, 34, 1.2);
    var caption = try Font.init(alloc, ui_regular, 26, 1.2);
    var hero = try Font.init(alloc, book_bold, 56, 1.2);
    var cover_type = try Font.init(alloc, book_bold, 36, 1.2);

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
    var journal_buf: [320]u8 = undefined;
    const journal_path = try std.fmt.bufPrintSentinel(&journal_buf, "{s}/journal", .{state_dir}, 0);
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
        .journal_path = journal_path,
        .journal = app.loadJournal(journal_path),
        .app_budget = &app_budget,
        .stb_budget = &stb_budget,
        .speed = app.loadSpeed(speed_path),
        .utc_offset = clock.utcOffset(),
        .settings = app.loadSettings(settings_path),
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &reference },
    };
    shared.applySettings() catch {
        shared.settings = .{};
        try shared.applySettings();
    };
    app.saveSettings(settings_path, shared.settings); // Older files come back in the current format
    try library_screen.runLibrary(&shared);
    std.debug.print("quit\n", .{});
}
