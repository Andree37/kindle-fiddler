//! What every screen shares: the screen, input, fonts, settings and page buffers.
const std = @import("std");
const memory = @import("base/memory.zig");
const fonts_db = @import("kindle/fonts.zig");
const settings_model = @import("model/settings.zig");
const Page = @import("gfx/page.zig").Page;
const Font = @import("gfx/font.zig").Font;
const book_model = @import("model/book.zig");
const stats = @import("model/stats.zig");
const cover = @import("gfx/image.zig");
const draw = @import("ui/draw.zig");
const state = @import("linux/state.zig");
const Fonts = @import("ui/fonts.zig").Fonts;
const input_mod = @import("kindle/input.zig");
const aa = @import("ui/aa.zig");
const file = @import("linux/file.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const library = @import("ui/library.zig");
const clock = @import("linux/clock.zig");
const jpegxr = @import("kindle/jpegxr.zig");
const quick_model = @import("model/quick.zig");
const text = @import("layout/text.zig");
const os = @import("linux/os.zig");
const Input = input_mod.Input;
const unixTime = os.unixTime;

pub const page_waveform: hwtcon.Waveform = .reagl;

pub const clock_top = 16;

pub const clock_height = 56;

pub const clock_width = 160;

pub const Slot = struct { page: i64 = -1, buf: []u8, hits: text.Hits = .{} };

pub const App = struct {
    alloc: std.mem.Allocator, // Lives as long as the app, counted by app_budget
    app_budget: *memory.Budget,
    stb_budget: *memory.Budget,
    screen: *hwtcon.Screen,
    input: *Input,
    body: *Font,
    // Body fonts by family, face (bold, italic), reader size and book size, made on first use.
    face_fonts: [settings_model.families.len][4][settings_model.sizes.len][book_model.size_scales.len]?Font = @splat(@splat(@splat(@splat(null)))),
    face_files: [settings_model.families.len][4]?[]const u8 = @splat(@splat(null)),
    tab: aa.Tab = .font,
    turns: u32 = 0,
    note_font: *Font,
    footer: *Font,
    ui: Fonts,
    slots: [3]Slot,
    overlay: []u8,
    lock_saved: []u8,
    lock_cover: []u8,
    state_dir: []const u8,
    library_path: [*:0]const u8,
    settings_path: [*:0]const u8,
    speed_path: [*:0]const u8,
    speed: stats.Speed = .{}, // How fast this reader reads, across every book
    pictures: Pictures = .{}, // Pictures of the open book, ready to copy onto pages
    settings: settings_model.Settings,
    quick: quick_model.Quick = .{},
    utc_offset: i64,
    clock_minute: u64 = 0,
    layout: text.Layout,

    /// Fonts are kept per size, so stepping through sizes doesn't reload them.
    pub fn applySettings(a: *App) !void {
        a.body = try a.face(false, false, book_model.normal_size);
        a.layout.faces = .{ .ctx = a, .pick = pickFace };
        a.layout.images = .{ .ctx = a, .draw = drawImage };
        a.layout.margin_x = settings_model.margins[a.settings.margin];
        a.layout.justify = !a.settings.left_align;
    }

    /// The body font for a weight, slant and book size, in the reader's family and size.
    /// The reader's Bold setting makes everything bold.
    pub fn face(a: *App, bold_text: bool, italic: bool, size: u8) !*Font {
        const bold = bold_text or a.settings.bold;
        const which: usize = @as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1;
        const file_slot = &a.face_files[a.settings.font][which];
        if (file_slot.* == null) file_slot.* = try file.map(fonts_db.path(a.settings.font, bold, italic));
        const scale = book_model.size_scales[size];
        const slot = &a.face_fonts[a.settings.font][which][a.settings.size][size];
        if (slot.* == null) slot.* = try Font.init(a.alloc, file_slot.*.?, a.settings.px() * scale, 1);
        // Spacing can change without the font changing, so set it every time.
        slot.*.?.line_height = @intFromFloat(@as(f32, @floatFromInt(a.settings.lineHeight())) * scale);
        return &slot.*.?;
    }

    fn drawImage(ctx: *anyopaque, page_buf: Page, image: book_model.Image, x: u32, y: u32, w: u32, h: u32) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        const ready = a.pictures.get(image.data.ptr, w, h) orelse blk: {
            const made = if (jpegxr.isJpegXr(image.data))
                preparedJpegXr(a.alloc, image.data, w, h)
            else
                cover.decodeAndPrepare(a.alloc, image.data, w, h);
            const pixels = made orelse {
                std.debug.print("picture not drawn\n", .{});
                return;
            };
            a.pictures.put(a.alloc, image.data.ptr, w, h, pixels);
            break :blk pixels;
        };
        cover.blit(page_buf, ready, x, y, w, h);
    }

    fn preparedJpegXr(alloc: std.mem.Allocator, data: []const u8, w: u32, h: u32) ?[]u8 {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const gray = jpegxr.decodeJpegXr(arena.allocator(), data, w, h) orelse return null;
        return cover.prepare(alloc, gray.pixels, gray.width, gray.height, w, h);
    }

    fn pickFace(ctx: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*Font {
        const a: *App = @ptrCast(@alignCast(ctx));
        return a.face(bold, italic, size) catch a.face(false, false, size);
    }

    pub fn page(a: *App, buf: []u8) Page {
        return .{ .buf = buf, .width = a.screen.width, .height = a.screen.height, .stride = a.screen.stride };
    }

    /// Outlines a book at once, using the fastest waveform, and waits so it can't
    /// collide with what's drawn next.
    pub fn flash(a: *App, r: library.Rect) void {
        const target = a.page(a.screen.pixels);
        const t = 6;
        target.fillRect(r.x, r.y, r.w, t, 0x00);
        target.fillRect(r.x, r.y + r.h - t, r.w, t, 0x00);
        target.fillRect(r.x, r.y, t, r.h, 0x00);
        target.fillRect(r.x + r.w - t, r.y, t, r.h, 0x00);
        const marker = a.screen.updateRegion(r.x, r.y, r.w, r.h, .du, .partial) catch return;
        a.screen.waitComplete(marker) catch {};
    }

    /// Writes the time into the page on screen, without refreshing the panel.
    pub fn stampClock(a: *App) void {
        if (!a.settings.clock) return;
        const target = a.page(a.screen.pixels);
        const left = (a.screen.width - clock_width) / 2;
        target.fillRect(left, clock_top, clock_width, clock_height, 0xff);
        var buf: [8]u8 = undefined;
        const time = clock.formatClock(&buf, @intCast(unixTime()), a.utc_offset);
        draw.centered(a.ui.caption, target, @floatFromInt(a.screen.width / 2), clock_top + 38, time) catch {};
        a.clock_minute = unixTime() / 60;
    }

    /// Redraws just the clock, which is too small to need a flash.
    pub fn updateClock(a: *App) !void {
        if (!a.settings.clock) return;
        a.stampClock();
        const left = (a.screen.width - clock_width) / 2;
        try a.screen.waitComplete(try a.screen.updateRegion(left, clock_top, clock_width, clock_height, .gl16, .partial));
    }

    /// Refreshes part of the screen with the page waveform, and waits for it.
    pub fn showRect(a: *App, left: u32, top: u32, width: u32, height: u32) !void {
        try a.screen.waitComplete(try a.screen.updateRegion(left, top, width, height, page_waveform, .partial));
    }

    /// Refreshes a full-width band of the screen, and waits for it.
    pub fn showBand(a: *App, top: u32, height: u32) !void {
        try a.showRect(0, top, a.screen.width, height);
    }

    /// The cached page buffer holding `page`, if any.
    pub fn slotFor(a: *App, page_index: usize) ?*Slot {
        for (&a.slots) |*slot| {
            if (slot.page == @as(i64, @intCast(page_index))) return slot;
        }
        return null;
    }

    /// Drops every cached page, after anything that changes how pages look.
    pub fn forgetPages(a: *App) void {
        for (&a.slots) |*slot| slot.page = -1;
    }

    /// Where a book's reading position is kept.
    pub fn statePath(a: *const App, buf: []u8, book_path: []const u8) ![:0]u8 {
        return state.pathFor(buf, a.state_dir, book_path);
    }

    pub fn present(a: *App, buf: []const u8, wf: hwtcon.Waveform, mode: hwtcon.UpdateMode) !void {
        @memcpy(a.screen.pixels, buf);
        try a.screen.waitComplete(try a.screen.update(wf, mode));
    }
};

pub const notice_ms = 1800;

/// Says something went wrong, over the page, for a moment.
pub fn showNotice(a: *App, message: []const u8) !void {
    const screen_page = a.page(a.screen.pixels);
    const width: u32 = 760;
    const height: u32 = 100;
    const left = (a.screen.width - width) / 2;
    const top = a.screen.height - 260;
    draw.box(screen_page, left, top, width, height);
    try draw.centered(a.ui.small, screen_page, @floatFromInt(left + width / 2), @intCast(top + 62), message);
    try a.showRect(left, top, width, height);
    os.sleepMs(notice_ms);
}

/// Clears everything the fast waveform left behind in a band.
pub fn cleanBand(a: *App, top: u32, height: u32) !void {
    try a.screen.waitComplete(try a.screen.updateRegion(0, top, a.screen.width, height, .gc16, .full));
}

/// Follows the dragged finger until it lifts. `follow.moved(x, y)` redraws for a
/// new position and returns the update to wait on, or null when nothing changed.
/// Only one update runs at a time: overlapping ones smear on the panel.
pub fn followDrag(a: *App, first: ?u32, follow: anytype) !void {
    var marker = first;
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |x0| {
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const x = a.input.latestDrag() orelse x0;
                marker = try follow.moved(x, a.input.drag_y);
            },
            .drag_end => break,
            .tap, .hold, .pull, .tick, .unlock => {},
            .lock, .power, .idle, .stop => {
                a.input.stashed = action;
                break;
            },
        }
    }
    if (marker) |m| try a.screen.waitComplete(m);
}

pub fn loadSpeed(path: [*:0]const u8) stats.Speed {
    var buf: [64]u8 = undefined;
    return stats.parse(state.readSmall(path, &buf));
}

pub fn saveSpeed(a: *const App) void {
    var buf: [64]u8 = undefined;
    state.writeSmall(a.speed_path, stats.format(&buf, a.speed));
}

pub fn loadSettings(path: [*:0]const u8) settings_model.Settings {
    var buf: [512]u8 = undefined;
    return settings_model.parse(state.readSmall(path, &buf));
}

pub fn saveSettings(path: [*:0]const u8, s: settings_model.Settings) void {
    var buf: [512]u8 = undefined;
    state.writeSmall(path, settings_model.format(&buf, s));
}

/// The last few pictures drawn, decoded, scaled and dithered, so drawing a page
/// again doesn't decode them again. Keyed by where the picture's bytes sit in the
/// open book, so it must be cleared when the book closes.
pub const Pictures = struct {
    const slots = 8;
    const Entry = struct { key: usize = 0, w: u32 = 0, h: u32 = 0, pixels: []u8 = &.{} };
    entries: [slots]Entry = @splat(.{}),
    next: usize = 0, // Which entry to replace next

    pub fn get(p: *const Pictures, data: [*]const u8, w: u32, h: u32) ?[]const u8 {
        for (p.entries) |e| {
            if (e.key == @intFromPtr(data) and e.w == w and e.h == h) return e.pixels;
        }
        return null;
    }

    pub fn put(p: *Pictures, alloc: std.mem.Allocator, data: [*]const u8, w: u32, h: u32, pixels: []u8) void {
        const e = &p.entries[p.next];
        if (e.key != 0) alloc.free(e.pixels);
        e.* = .{ .key = @intFromPtr(data), .w = w, .h = h, .pixels = pixels };
        p.next = (p.next + 1) % slots;
    }

    pub fn clear(p: *Pictures, alloc: std.mem.Allocator) void {
        for (&p.entries) |*e| {
            if (e.key != 0) alloc.free(e.pixels);
            e.* = .{};
        }
        p.next = 0;
    }
};

test "pictures are kept until replaced or cleared" {
    const alloc = std.testing.allocator;
    var p = Pictures{};
    defer p.clear(alloc);
    const key = "abc";
    p.put(alloc, key.ptr, 2, 1, try alloc.dupe(u8, "xy"));
    try std.testing.expectEqualStrings("xy", p.get(key.ptr, 2, 1).?);
    try std.testing.expect(p.get(key.ptr, 4, 2) == null); // Another size
    for (0..Pictures.slots) |i| p.put(alloc, @ptrFromInt(0x1000 + i), 1, 1, try alloc.dupe(u8, "z"));
    try std.testing.expect(p.get(key.ptr, 2, 1) == null); // Pushed out
}
