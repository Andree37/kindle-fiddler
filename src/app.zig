//! What every screen shares: the screen, input, fonts, settings and page buffers.
const std = @import("std");
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
    body_fonts: [menu.families.len][2][menu.sizes.len]?text.Font = @splat(@splat(@splat(null))),
    font_files: [menu.families.len][2]?[]const u8 = @splat(@splat(null)),
    tab: aa.Tab = .font,
    turns: u32 = 0,
    note_font: *text.Font,
    footer: *text.Font,
    ui: library.Fonts,
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
        const family = a.settings.font;
        const weight: usize = @intFromBool(a.settings.bold);
        if (a.font_files[family][weight] == null) a.font_files[family][weight] = try file.map(a.settings.fontPath());
        const slot = &a.body_fonts[family][weight][a.settings.size];
        if (slot.* == null) slot.* = try text.Font.init(a.alloc, a.font_files[family][weight].?, a.settings.px(), 1);
        a.layout.margin_x = menu.margins[a.settings.margin];
        a.layout.justify = !a.settings.left_align;
        slot.*.?.line_height = a.settings.lineHeight();
        a.body = &slot.*.?;
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
        const width = a.ui.caption.measure(time) catch return;
        const x = @as(f32, @floatFromInt(a.screen.width)) / 2 - width / 2;
        a.ui.caption.draw(target, x, clock_top + 38, time) catch {};
        a.clock_minute = unixTime() / 60;
    }

    /// Redraws just the clock, which is too small to need a flash.
    pub fn updateClock(a: *App) !void {
        if (!a.settings.clock) return;
        a.stampClock();
        const left = (a.screen.width - clock_width) / 2;
        try a.screen.waitComplete(try a.screen.updateRegion(left, clock_top, clock_width, clock_height, .gl16, .partial));
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
    screen_page.fillRect(left, top, width, height, 0x00);
    screen_page.fillRect(left + 3, top + 3, width - 6, height - 6, 0xff);
    const label = try a.ui.small.measure(message);
    try a.ui.small.draw(screen_page, @as(f32, @floatFromInt(left + width / 2)) - label / 2, @intCast(top + 62), message);
    try a.screen.waitComplete(try a.screen.updateRegion(left, top, width, height, page_waveform, .partial));
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
