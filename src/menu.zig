//! Bar shown over a book: tap the top of a page to open it.
const std = @import("std");
const library = @import("library.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const text = @import("text.zig");

const panel_height = 780; // Status, shortcuts and brightness
const toolbar_bottom = 900; // Library and Kindle, inside a book only
const book_height = 1040; // Plus text settings

const slider_left = 160;
const slider_right = 1110;
const slider_y = 680;

/// The book rows only apply inside a book.
pub fn height(in_book: bool) u32 {
    return if (in_book) book_height else panel_height;
}

pub const sizes = [_]f32{ 36, 40, 46, 52, 58, 66 };
pub const spacings = [_]f32{ 1.2, 1.35, 1.5, 1.7 };

pub const Settings = struct {
    size: usize = 2,
    spacing: usize = 1,

    pub fn px(s: Settings) f32 {
        return sizes[s.size];
    }

    pub fn lineHeight(s: Settings) i32 {
        return @intFromFloat(sizes[s.size] * spacings[s.spacing]);
    }
};

/// Moves within 0..len, stopping at both ends.
pub fn step(value: usize, delta: i32, len: usize) usize {
    if (delta < 0) return value -| 1;
    return @min(value + 1, len - 1);
}

pub const Hit = enum { none, close, library, kindle, smaller, larger, tighter, looser, dimmer, brighter, slider, airplane, settings };

const Button = struct { hit: Hit, label: []const u8, left: i32, right: i32 };
const text_buttons = [_]Button{
    .{ .hit = .smaller, .label = "-", .left = 300, .right = 420 },
    .{ .hit = .larger, .label = "+", .left = 440, .right = 560 },
    .{ .hit = .tighter, .label = "-", .left = 880, .right = 1000 },
    .{ .hit = .looser, .label = "+", .left = 1020, .right = 1140 },
};

const Shortcut = struct { hit: Hit, label: []const u8, x: i32, y: i32 };
const icon_radius = 52;
const shortcuts = [_]Shortcut{
    .{ .hit = .airplane, .label = "", .x = 318, .y = 240 },
    .{ .hit = .none, .label = "Off", .x = 636, .y = 240 }, // Bluetooth, not wired up yet
    .{ .hit = .none, .label = "Sync", .x = 954, .y = 240 }, // Not wired up yet
    .{ .hit = .settings, .label = "All Settings", .x = 636, .y = 430 },
};

/// Brightness level for a tap at `x` on the slider.
pub fn levelAt(x: i32) u32 {
    const span = slider_right - slider_left;
    const clamped = std.math.clamp(x, slider_left, slider_right);
    return @intCast(@divTrunc((clamped - slider_left) * system.max_brightness + span / 2, span));
}

pub fn hit(x: i32, y: i32, width: i32, in_book: bool) Hit {
    if (y >= height(in_book)) return .close;
    if (y >= panel_height) {
        if (y < toolbar_bottom) {
            if (x < 300) return .library;
            if (x >= width - 300) return .kindle;
            return .none;
        }
        for (text_buttons) |b| {
            if (x >= b.left and x < b.right) return b.hit;
        }
        return .none;
    }
    if (y >= slider_y - 60) {
        if (y >= slider_y + 60) return .close; // The chevron
        if (x < slider_left) return .dimmer;
        if (x > slider_right) return .brighter;
        return .slider;
    }
    for (shortcuts) |s| {
        if (@abs(x - s.x) < 120 and @abs(y - s.y) < 95) return s.hit;
    }
    return .none;
}

fn centered(font: *text.Font, page: text.Page, cx: i32, y: i32, s: []const u8) !void {
    const w: i32 = @intFromFloat(try font.measure(s));
    try font.draw(page, @floatFromInt(cx - @divTrunc(w, 2)), y, s);
}

fn drawIcon(fonts: library.Fonts, page: text.Page, index: usize, cx: i32, cy: i32) !void {
    page.disc(cx, cy, icon_radius, icon_radius - 4, 0x00);
    const x: u32 = @intCast(cx);
    const y: u32 = @intCast(cy);
    switch (index) {
        0 => { // Airplane
            page.fillRect(x - 3, y - 32, 6, 64, 0x00);
            page.fillRect(x - 28, y - 6, 56, 6, 0x00);
            page.fillRect(x - 12, y + 22, 24, 5, 0x00);
        },
        1 => try centered(fonts.title, page, cx, cy + 15, "B"), // Bluetooth
        2 => { // Sync
            page.disc(cx, cy, 28, 22, 0x00);
            page.fillRect(x - 34, y - 4, 68, 8, 0xff);
            page.fillRect(x + 16, y - 16, 22, 6, 0x00);
            page.fillRect(x - 38, y + 10, 22, 6, 0x00);
        },
        else => { // Settings
            page.disc(cx, cy, 22, 13, 0x00);
            page.fillRect(x - 4, y - 34, 8, 12, 0x00);
            page.fillRect(x - 4, y + 22, 8, 12, 0x00);
            page.fillRect(x - 34, y - 4, 12, 8, 0x00);
            page.fillRect(x + 22, y - 4, 12, 8, 0x00);
        },
    }
}

pub fn render(fonts: library.Fonts, page: text.Page, title: []const u8, in_book: bool, quick: *const system.Quick) !void {
    const h = height(in_book);
    const w: f32 = @floatFromInt(page.width);
    page.fillRect(0, 0, page.width, h, 0xff);
    page.fillRect(0, h - 4, page.width, 4, 0x00);

    try fonts.title.draw(page, 60, 70, "Kindle Paperwhite");
    try fonts.small.draw(page, 60, 120, quick.clockText());
    var pct: [8]u8 = undefined;
    try fonts.small.draw(page, w - 230, 70, std.fmt.bufPrint(&pct, "{d}%", .{quick.battery}) catch "");
    const battery_x: u32 = page.width - 130;
    page.fillRect(battery_x, 44, 70, 32, 0x00);
    page.fillRect(battery_x + 3, 47, 64, 26, 0xff);
    page.fillRect(battery_x + 70, 52, 6, 16, 0x00);
    page.fillRect(battery_x + 5, 49, 60 * @min(quick.battery, 100) / 100, 22, 0x00);

    for (shortcuts, 0..) |s, i| {
        try drawIcon(fonts, page, i, s.x, s.y);
        const label = if (s.hit == .airplane) (if (quick.airplane) "On" else "Off") else s.label;
        try centered(fonts.small, page, s.x, s.y + 92, label);
    }

    page.fillRect(40, 560, page.width - 80, 2, 0x80);
    try fonts.small.draw(page, 60, 610, "Brightness");
    const knob_x: i32 = slider_left + @divTrunc(@as(i32, @intCast(@min(quick.brightness, system.max_brightness))) * (slider_right - slider_left), system.max_brightness);
    var level: [8]u8 = undefined;
    try centered(fonts.small, page, knob_x, 645, std.fmt.bufPrint(&level, "{d}", .{quick.brightness}) catch "");
    try centered(fonts.title, page, 90, slider_y + 14, "-");
    try centered(fonts.title, page, 1180, slider_y + 14, "+");
    page.fillRect(slider_left, slider_y - 2, slider_right - slider_left, 4, 0x80);
    page.fillRect(slider_left, slider_y - 4, @intCast(knob_x - slider_left), 8, 0x00);
    page.disc(knob_x, slider_y, 24, 0, 0x00);
    page.disc(knob_x, slider_y, 21, 0, 0xff);

    // Chevron that closes the panel
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        const rise = (40 - i) / 3;
        page.fillRect(page.width / 2 - 40 + i, 748 + 13 - rise, 3, 4, 0x00);
        page.fillRect(page.width / 2 + i, 748 + i / 3, 3, 4, 0x00);
    }

    if (!in_book) return;
    page.fillRect(0, panel_height - 2, page.width, 2, 0x80);
    try fonts.title.draw(page, 60, 860, "< Library");
    try library.drawClipped(fonts.small, page, 320, 860, title, 620);
    try fonts.title.draw(page, w - 200, 860, "Kindle");
    page.fillRect(0, toolbar_bottom, page.width, 2, 0x80);
    try fonts.small.draw(page, 60, 990, "Text size");
    try fonts.small.draw(page, 640, 990, "Spacing");
    for (text_buttons) |b| {
        const left: u32 = @intCast(b.left);
        page.fillRect(left, 930, @intCast(b.right - b.left), 90, 0xe0);
        try fonts.title.draw(page, @floatFromInt(left + 48), 990, b.label);
    }
}

/// Settings share the state file format: size, then spacing.
pub fn load(path: [*:0]const u8) Settings {
    const s = state.load(path);
    return .{ .size = @min(if (s.opened == 0) 2 else s.para, sizes.len - 1), .spacing = @min(if (s.opened == 0) 1 else s.byte, spacings.len - 1) };
}

pub fn save(path: [*:0]const u8, s: Settings) void {
    state.save(path, .{ .para = s.size, .byte = s.spacing, .opened = 1 });
}

test "panel maps taps like the stock layout" {
    try std.testing.expectEqual(Hit.airplane, hit(318, 240, 1272, false));
    try std.testing.expectEqual(Hit.none, hit(636, 240, 1272, false));
    try std.testing.expectEqual(Hit.none, hit(954, 240, 1272, false));
    try std.testing.expectEqual(Hit.settings, hit(636, 430, 1272, false));
    try std.testing.expectEqual(Hit.dimmer, hit(90, 680, 1272, false));
    try std.testing.expectEqual(Hit.brighter, hit(1180, 680, 1272, false));
    try std.testing.expectEqual(Hit.slider, hit(600, 680, 1272, false));
    try std.testing.expectEqual(Hit.close, hit(636, 760, 1272, false));
    try std.testing.expectEqual(Hit.close, hit(600, 1000, 1272, false));
}

test "book rows sit under the panel" {
    try std.testing.expectEqual(Hit.library, hit(100, 840, 1272, true));
    try std.testing.expectEqual(Hit.kindle, hit(1100, 840, 1272, true));
    try std.testing.expectEqual(Hit.smaller, hit(350, 970, 1272, true));
    try std.testing.expectEqual(Hit.looser, hit(1100, 970, 1272, true));
    try std.testing.expectEqual(Hit.close, hit(600, 1200, 1272, true));
}

test "slider maps position to level" {
    try std.testing.expectEqual(@as(u32, 0), levelAt(160));
    try std.testing.expectEqual(@as(u32, 24), levelAt(1110));
    try std.testing.expectEqual(@as(u32, 12), levelAt(635));
    try std.testing.expectEqual(@as(u32, 24), levelAt(1200));
}

test "steps stop at both ends" {
    try std.testing.expectEqual(@as(usize, 0), step(0, -1, 6));
    try std.testing.expectEqual(@as(usize, 5), step(5, 1, 6));
    try std.testing.expectEqual(@as(usize, 3), step(2, 1, 6));
}

test "defaults match the original reader" {
    const s = Settings{};
    try std.testing.expectEqual(@as(f32, 46), s.px());
    try std.testing.expectEqual(@as(i32, 62), s.lineHeight());
}
