//! Quick panel: drag down from the top of any screen to open it.
const std = @import("std");
const icons = @import("icons.zig");
const library = @import("library.zig");
const slider = @import("slider.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const text = @import("text.zig");

pub const height = 960;

const slider_left = 160;
const slider_right = 1110;

pub const Row = struct { label: []const u8, y: u32, max: u32 };
pub const brightness_row = Row{ .label = "Brightness", .y = 680, .max = system.max_brightness };
pub const warmth_row = Row{ .label = "Warmth", .y = 850, .max = system.max_warmth };
const schedule_top = 754;
const schedule_bottom = 794;

pub const Family = struct { label: []const u8, path: [*:0]const u8 };
const font_dir = "/usr/java/lib/fonts/";
pub const families = [_]Family{
    .{ .label = "Ember", .path = font_dir ++ "Amazon-Ember-Regular.ttf" },
    .{ .label = "Bookerly", .path = font_dir ++ "Bookerly-Regular.ttf" },
    .{ .label = "Baskerville", .path = font_dir ++ "Baskerville-Regular.ttf" },
    .{ .label = "Serif", .path = font_dir ++ "AmazonEmberSerif_Rg.ttf" },
};

pub const sizes = [_]f32{ 36, 40, 46, 52, 58, 66 };
pub const spacings = [_]f32{ 1.2, 1.35, 1.5, 1.7 };

pub const Settings = struct {
    size: usize = 2,
    spacing: usize = 1,
    font: usize = 0,

    pub fn px(s: Settings) f32 {
        return sizes[s.size];
    }

    pub fn lineHeight(s: Settings) i32 {
        return @intFromFloat(sizes[s.size] * spacings[s.spacing]);
    }
};

pub const Hit = enum { none, close, dimmer, brighter, slider, cooler, warmer, warmth, schedule, airplane, settings, sync };

const Icon = enum { airplane, wifi, bluetooth, sync, gear };
const Shortcut = struct { icon: Icon, hit: Hit, x: i32, y: i32 };
const icon_radius = 52;
const shortcuts = [_]Shortcut{
    .{ .icon = .airplane, .hit = .airplane, .x = 318, .y = 240 },
    .{ .icon = .wifi, .hit = .settings, .x = 636, .y = 240 }, // Networks live in stock settings
    .{ .icon = .bluetooth, .hit = .none, .x = 954, .y = 240 }, // Not wired up yet
    .{ .icon = .sync, .hit = .sync, .x = 477, .y = 430 },
    .{ .icon = .gear, .hit = .settings, .x = 795, .y = 430 },
};

fn rowSlider(row: Row) slider.Slider {
    return .{ .left = slider_left, .right = slider_right, .y = row.y };
}

/// Level for a tap at `x` on a row's slider.
pub fn levelAt(row: Row, x: i32) u32 {
    return slider.valueAt(rowSlider(row), x, row.max);
}

pub fn hit(x: i32, y: i32) Hit {
    if (y >= height) return .close;
    if (y >= warmth_row.y + 60) return .close; // The chevron
    if (y >= schedule_top and y < schedule_bottom and x >= 800) return .schedule;
    if (y >= warmth_row.y - 60) {
        if (x < slider_left) return .cooler;
        if (x > slider_right) return .warmer;
        return .warmth;
    }
    if (y >= brightness_row.y - 60 and y < brightness_row.y + 60) {
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

const band_above = 60;
const band_below = 50;

pub fn bandTop(row: Row) u32 {
    return row.y - band_above;
}

pub const band_height = band_above + band_below;

/// One slider row, redrawn alone while dragging. `mono` is pure black and white
/// for the fast waveform, which breaks up gray.
pub fn drawSlider(fonts: library.Fonts, page: text.Page, row: Row, value: u32, mono: bool) !void {
    page.fillRect(0, bandTop(row), page.width, band_height, 0xff);
    const bar = rowSlider(row);
    const knob = slider.knobAt(bar, value, row.max);
    var level: [8]u8 = undefined;
    try centered(fonts.small, page, @intCast(knob), @intCast(row.y - 40), std.fmt.bufPrint(&level, "{d}", .{value}) catch "");
    const y: f32 = @floatFromInt(row.y);
    page.stroke(70, y, 110, y, 4);
    page.stroke(1160, y, 1200, y, 4);
    page.stroke(1180, y - 20, 1180, y + 20, 4);
    slider.draw(page, bar, knob);
    if (mono) page.threshold(bandTop(row), band_height);
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
    if (isOn(s, quick)) page.invertDisc(s.x, s.y, icon_radius - 1);
}

/// Toggles fill when on, like the stock panel.
pub fn isOn(s: Shortcut, quick: *const system.Quick) bool {
    return switch (s.icon) {
        .airplane => quick.airplane,
        .wifi => quick.wifi_on,
        else => false,
    };
}

fn label(s: Shortcut, quick: *const system.Quick) []const u8 {
    return switch (s.icon) {
        .airplane => if (quick.airplane) "On" else "Off",
        .wifi => if (quick.wifi_on) "Connected" else "Wi-Fi Off",
        .bluetooth => "Off",
        .sync => if (quick.syncing) "Syncing" else "Sync",
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
    try fonts.small.draw(page, 60, 606, brightness_row.label);
    try drawSlider(fonts, page, brightness_row, quick.brightness, false);
    try fonts.small.draw(page, 60, 776, warmth_row.label);
    const schedule = if (quick.schedule) "Schedule: On" else "Schedule: Off";
    const schedule_w = try fonts.small.measure(schedule);
    try fonts.small.draw(page, w - 96 - schedule_w, 776, schedule);
    page.stroke(w - 80, 752, w - 66, 766, 4);
    page.stroke(w - 66, 766, w - 80, 780, 4);
    try drawSlider(fonts, page, warmth_row, quick.warmth, false);
    icons.chevron(page, w / 2, 934);

}

/// Settings share the state file format: size, spacing, font.
pub fn load(path: [*:0]const u8) Settings {
    const s = state.load(path);
    if (s.opened == 0) return .{};
    return .{
        .size = @min(s.para, sizes.len - 1),
        .spacing = @min(s.byte, spacings.len - 1),
        .font = @min(s.percent orelse 0, families.len - 1),
    };
}

pub fn save(path: [*:0]const u8, s: Settings) void {
    state.save(path, .{ .para = s.size, .byte = s.spacing, .percent = @intCast(s.font), .opened = 1 });
}

test "panel maps taps like the stock layout" {
    try std.testing.expectEqual(Hit.airplane, hit(318, 240));
    try std.testing.expectEqual(Hit.settings, hit(636, 240)); // Wi-Fi
    try std.testing.expectEqual(Hit.none, hit(954, 240)); // Bluetooth
    try std.testing.expectEqual(Hit.sync, hit(477, 430));
    try std.testing.expectEqual(Hit.settings, hit(795, 430));
    try std.testing.expectEqual(Hit.none, hit(954, 430));
    try std.testing.expectEqual(Hit.dimmer, hit(90, 680));
    try std.testing.expectEqual(Hit.brighter, hit(1180, 680));
    try std.testing.expectEqual(Hit.slider, hit(600, 680));
    try std.testing.expectEqual(Hit.cooler, hit(90, 850));
    try std.testing.expectEqual(Hit.warmer, hit(1180, 850));
    try std.testing.expectEqual(Hit.warmth, hit(600, 850));
    try std.testing.expectEqual(Hit.schedule, hit(1000, 775));
    try std.testing.expectEqual(Hit.close, hit(636, 930));
    try std.testing.expectEqual(Hit.close, hit(600, 1100));
}

test "sliders map position to level" {
    try std.testing.expectEqual(@as(u32, 0), levelAt(brightness_row, 160));
    try std.testing.expectEqual(@as(u32, 24), levelAt(brightness_row, 1110));
    try std.testing.expectEqual(@as(u32, 12), levelAt(warmth_row, 635));
    try std.testing.expectEqual(@as(u32, 24), levelAt(warmth_row, 1200));
}

test "defaults match the original reader" {
    const s = Settings{};
    try std.testing.expectEqual(@as(f32, 46), s.px());
    try std.testing.expectEqual(@as(i32, 62), s.lineHeight());
}

test "toggles report their state" {
    const on = system.Quick{ .airplane = true, .wifi_on = true };
    const off = system.Quick{};
    try std.testing.expect(isOn(shortcuts[0], &on));
    try std.testing.expect(!isOn(shortcuts[0], &off));
    try std.testing.expect(isOn(shortcuts[1], &on));
    try std.testing.expect(!isOn(shortcuts[2], &on));
}
