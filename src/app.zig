//! What every screen shares: the screen, input, fonts, settings and page buffers.
const std = @import("std");
const cover = @import("ui/cover.zig");
const kfx = @import("book/kfx.zig");
const draw = @import("ui/draw.zig");
const state = @import("platform/state.zig");
const Fonts = @import("ui/fonts.zig").Fonts;
const input_mod = @import("platform/input.zig");
const aa = @import("ui/aa.zig");
const file = @import("platform/file.zig");
const hwtcon = @import("platform/hwtcon.zig");
const library = @import("ui/library.zig");
const menu = @import("ui/menu.zig");
const system = @import("platform/system.zig");
const text = @import("book/text.zig");
const os = @import("platform/os.zig");
const Input = input_mod.Input;
const unixTime = os.unixTime;
const panel = @import("screens/panel.zig");

pub const page_waveform: hwtcon.Waveform = .reagl;

pub const clock_top = 16;

pub const clock_height = 56;

pub const clock_width = 160;

pub const Slot = struct { page: i64 = -1, buf: []u8, hits: text.Hits = .{} };

pub const App = struct {
    alloc: std.mem.Allocator,
    screen: *hwtcon.Screen,
    input: *Input,
    body: *text.Font,
    // Body fonts by family, face (bold, italic), reader size and book size, made on first use.
    face_fonts: [menu.families.len][4][menu.sizes.len][kfx.size_scales.len]?text.Font = @splat(@splat(@splat(@splat(null)))),
    face_files: [menu.families.len][4]?[]const u8 = @splat(@splat(null)),
    tab: aa.Tab = .font,
    turns: u32 = 0,
    note_font: *text.Font,
    footer: *text.Font,
    ui: Fonts,
    slots: [3]Slot,
    overlay: []u8,
    lock_saved: []u8,
    lock_cover: []u8,
    state_dir: []const u8,
    library_path: [*:0]const u8,
    settings_path: [*:0]const u8,
    settings: menu.Settings,
    quick: system.Quick = .{},
    utc_offset: i64,
    clock_minute: u64 = 0,
    layout: text.Layout,

    /// Fonts are kept per size, so stepping through sizes doesn't reload them.
    pub fn applySettings(a: *App) !void {
        a.body = try a.face(false, false, kfx.normal_size);
        a.layout.faces = .{ .ctx = a, .pick = pickFace };
        a.layout.images = .{ .ctx = a, .draw = drawImage };
        a.layout.margin_x = menu.margins[a.settings.margin];
        a.layout.justify = !a.settings.left_align;
    }

    /// The body font for a weight, slant and book size, in the reader's family and size.
    /// The reader's Bold setting makes everything bold.
    pub fn face(a: *App, bold_text: bool, italic: bool, size: u8) !*text.Font {
        const family = menu.families[a.settings.font];
        const bold = bold_text or a.settings.bold;
        const which: usize = @as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1;
        const file_slot = &a.face_files[a.settings.font][which];
        if (file_slot.* == null) file_slot.* = try file.map(family.path(bold, italic));
        const scale = kfx.size_scales[size];
        const slot = &a.face_fonts[a.settings.font][which][a.settings.size][size];
        if (slot.* == null) slot.* = try text.Font.init(a.alloc, file_slot.*.?, a.settings.px() * scale, 1);
        // Spacing can change without the font changing, so set it every time.
        slot.*.?.line_height = @intFromFloat(@as(f32, @floatFromInt(a.settings.lineHeight())) * scale);
        return &slot.*.?;
    }

    fn drawImage(ctx: *anyopaque, page_buf: text.Page, image: kfx.Image, x: u32, y: u32, w: u32, h: u32) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        const drawn = if (system.isJpegXr(image.data)) blk: {
            var arena = std.heap.ArenaAllocator.init(a.alloc);
            defer arena.deinit();
            const gray = system.decodeJpegXr(arena.allocator(), image.data, image.width, image.height) orelse break :blk false;
            break :blk cover.placeGray(a.alloc, gray.pixels, gray.width, gray.height, page_buf, x, y, w, h);
        } else cover.place(a.alloc, image.data, page_buf, x, y, w, h);
        if (!drawn) std.debug.print("picture not drawn\n", .{});
    }

    fn pickFace(ctx: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*text.Font {
        const a: *App = @ptrCast(@alignCast(ctx));
        return a.face(bold, italic, size) catch a.face(false, false, size);
    }

    pub fn page(a: *App, buf: []u8) text.Page {
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
        const time = system.formatClock(&buf, @intCast(unixTime()), a.utc_offset);
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

pub fn loadSettings(path: [*:0]const u8) menu.Settings {
    return menu.decode(state.load(path));
}

pub fn saveSettings(path: [*:0]const u8, s: menu.Settings) void {
    state.save(path, menu.encode(s));
}
