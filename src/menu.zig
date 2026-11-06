//! Quick panel: drag down from the top of any screen to open it.
const std = @import("std");
const icons = @import("icons.zig");
const library = @import("library.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const text = @import("text.zig");

pub const height = 780;

const slider_left = 160;
const slider_right = 1110;
const slider_y = 680;

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

pub const Hit = enum { none, close, dimmer, brighter, slider, airplane, settings };

const Icon = enum { airplane, wifi, bluetooth, sync, gear };
const Shortcut = struct { icon: Icon, hit: Hit, x: i32, y: i32 };
const icon_radius = 52;
const shortcuts = [_]Shortcut{
    .{ .icon = .airplane, .hit = .airplane, .x = 318, .y = 240 },
    .{ .icon = .wifi, .hit = .settings, .x = 636, .y = 240 }, // Networks live in stock settings
    .{ .icon = .bluetooth, .hit = .none, .x = 954, .y = 240 }, // Not wired up yet
    .{ .icon = .sync, .hit = .none, .x = 477, .y = 430 }, // Not wired up yet
    .{ .icon = .gear, .hit = .settings, .x = 795, .y = 430 },
};

/// Brightness level for a tap at `x` on the slider.
pub fn levelAt(x: i32) u32 {
    const span = slider_right - slider_left;
    const clamped = std.math.clamp(x, slider_left, slider_right);
    return @intCast(@divTrunc((clamped - slider_left) * system.max_brightness + span / 2, span));
}

pub fn hit(x: i32, y: i32) Hit {
    if (y >= height) return .close;
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

pub const slider_top = 620;
pub const slider_height = 110;

/// Just the slider, which is redrawn alone while dragging. `mono` draws it in pure
/// black and white for the fast waveform, which breaks up gray.
pub fn drawSlider(fonts: library.Fonts, page: text.Page, quick: *const system.Quick, mono: bool) !void {
    page.fillRect(0, slider_top, page.width, slider_height, 0xff);
    const knob_x: i32 = slider_left + @divTrunc(@as(i32, @intCast(@min(quick.brightness, system.max_brightness))) * (slider_right - slider_left), system.max_brightness);
    var level: [8]u8 = undefined;
    try centered(fonts.small, page, knob_x, 647, std.fmt.bufPrint(&level, "{d}", .{quick.brightness}) catch "");
    page.stroke(70, slider_y, 110, slider_y, 4);
    page.stroke(1160, slider_y, 1200, slider_y, 4);
    page.stroke(1180, slider_y - 20, 1180, slider_y + 20, 4);
    page.fillRect(slider_left, slider_y - 2, slider_right - slider_left, 4, if (mono) 0x00 else 0xa0);
    page.fillRect(slider_left, slider_y - 4, @intCast(knob_x - slider_left), 8, 0x00);
    page.disc(knob_x, slider_y, 25, 0, 0x00);
    page.disc(knob_x, slider_y, 21, 0, 0xff);
    if (mono) page.threshold(slider_top, slider_height);
}

fn drawIcon(page: text.Page, s: Shortcut, quick: *const system.Quick) void {
    const x: f32 = @floatFromInt(s.x);
    const y: f32 = @floatFromInt(s.y);
    icons.ring(page, x, y, icon_radius);
    switch (s.icon) {
        .airplane => icons.airplane(page, x, y),
        .wifi => icons.wifi(page, x, y - 4, 0.8, if (quick.wifi_on) quick.wifi_bars else 0),
        .bluetooth => icons.bluetooth(page, x, y),
        .sync => icons.sync(page, x, y),
        .gear => icons.gear(page, x, y),
    }
}

fn label(s: Shortcut, quick: *const system.Quick) []const u8 {
    return switch (s.icon) {
        .airplane => if (quick.airplane) "On" else "Off",
        .wifi => if (quick.wifi_on) "Connected" else "Wi-Fi Off",
        .bluetooth => "Off",
        .sync => "Sync",
        .gear => "All Settings",
    };
}

pub fn render(fonts: library.Fonts, page: text.Page, quick: *const system.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    page.fillRect(0, 0, page.width, height, 0xff);
    page.fillRect(0, height - 4, page.width, 4, 0x00);

    try fonts.title.draw(page, 60, 70, "Kindle Paperwhite");
    try fonts.small.draw(page, 60, 120, quick.clockText());
    try icons.statusCluster(page, fonts.small, w - 60, 58, 70, quick, true);

    for (shortcuts) |s| {
        drawIcon(page, s, quick);
        try centered(fonts.small, page, s.x, s.y + 92, label(s, quick));
    }

    page.fillRect(40, 560, page.width - 80, 2, 0x80);
    try fonts.small.draw(page, 60, 610, "Brightness");
    try drawSlider(fonts, page, quick, false);
    icons.chevron(page, w / 2, 754);

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
    try std.testing.expectEqual(Hit.airplane, hit(318, 240));
    try std.testing.expectEqual(Hit.settings, hit(636, 240)); // Wi-Fi
    try std.testing.expectEqual(Hit.none, hit(954, 240)); // Bluetooth
    try std.testing.expectEqual(Hit.none, hit(477, 430)); // Sync
    try std.testing.expectEqual(Hit.settings, hit(795, 430));
    try std.testing.expectEqual(Hit.none, hit(954, 430));
    try std.testing.expectEqual(Hit.dimmer, hit(90, 680));
    try std.testing.expectEqual(Hit.brighter, hit(1180, 680));
    try std.testing.expectEqual(Hit.slider, hit(600, 680));
    try std.testing.expectEqual(Hit.close, hit(636, 760));
    try std.testing.expectEqual(Hit.close, hit(600, 1000));
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
