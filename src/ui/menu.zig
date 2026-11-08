//! Quick panel: drag down from the top of any screen to open it.
const std = @import("std");
const Fonts = @import("fonts.zig").Fonts;
const icons = @import("icons.zig");
const slider = @import("slider.zig");
const state = @import("../linux/state.zig");
const quick_model = @import("../model/quick.zig");
const text = @import("../layout/text.zig");

pub const height = 960;

const slider_left = 160;
const slider_right = 1110;

pub const Row = struct { label: []const u8, y: u32, max: u32 };
pub const brightness_row = Row{ .label = "Brightness", .y = 680, .max = quick_model.max_brightness };
pub const warmth_row = Row{ .label = "Warmth", .y = 850, .max = quick_model.max_warmth };
const schedule_top = 754;
const schedule_bottom = 794;

/// A typeface's four files: regular, bold, italic and bold italic, in that order.
pub const Family = struct {
    label: []const u8,
    faces: [4][*:0]const u8,

    /// The file for a weight and slant.
    pub fn path(f: Family, bold: bool, italic: bool) [*:0]const u8 {
        return f.faces[@as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1];
    }
};
const font_dir = "/usr/java/lib/fonts/";
pub const families = [_]Family{
    .{ .label = "Ember", .faces = .{ font_dir ++ "Amazon-Ember-Regular.ttf", font_dir ++ "Amazon-Ember-Bold.ttf", font_dir ++ "Amazon-Ember-RegularItalic.ttf", font_dir ++ "Amazon-Ember-BoldItalic.ttf" } },
    .{ .label = "Bookerly", .faces = .{ font_dir ++ "Bookerly-Regular.ttf", font_dir ++ "Bookerly-Bold.ttf", font_dir ++ "Bookerly-Italic.ttf", font_dir ++ "Bookerly-BoldItalic.ttf" } },
    .{ .label = "Baskerville", .faces = .{ font_dir ++ "Baskerville-Regular.ttf", font_dir ++ "Baskerville-Bold.ttf", font_dir ++ "Baskerville-Italic.ttf", font_dir ++ "Baskerville-BoldItalic.ttf" } },
    .{ .label = "Serif", .faces = .{ font_dir ++ "AmazonEmberSerif_Rg.ttf", font_dir ++ "AmazonEmberSerif_Bd.ttf", font_dir ++ "AmazonEmberSerif_RgIt.ttf", font_dir ++ "AmazonEmberSerif_BdIt.ttf" } },
};

pub const sizes = [_]f32{ 36, 40, 46, 52, 58, 66 };
pub const spacings = [_]f32{ 1.2, 1.35, 1.5, 1.7 };
pub const margins = [_]i32{ 60, 100, 150, 210 };

pub const Settings = struct {
    size: usize = 2,
    spacing: usize = 1,
    font: usize = 0,
    margin: usize = 1,
    bold: bool = false,
    left_align: bool = false,
    clock: bool = true,
    refresh: bool = false,
    time_left: bool = true,

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
pub fn drawSlider(fonts: Fonts, page: text.Page, row: Row, value: u32, mono: bool) !void {
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

fn drawIcon(page: text.Page, s: Shortcut, quick: *const quick_model.Quick) void {
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
pub fn isOn(s: Shortcut, quick: *const quick_model.Quick) bool {
    return switch (s.icon) {
        .airplane => quick.airplane,
        .wifi => quick.wifi_on,
        else => false,
    };
}

fn label(s: Shortcut, quick: *const quick_model.Quick) []const u8 {
    return switch (s.icon) {
        .airplane => if (quick.airplane) "On" else "Off",
        .wifi => if (quick.wifi_on) "Connected" else "Wi-Fi Off",
        .bluetooth => "Off",
        .sync => if (quick.syncing) "Syncing" else "Sync",
        .gear => "All Settings",
    };
}

pub fn render(fonts: Fonts, page: text.Page, quick: *const quick_model.Quick) !void {
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

const format_packed = 2;

/// Settings share the state file format, with everything packed into two numbers.
pub fn decode(saved: state.State) Settings {
    if (saved.opened == 0) return .{};
    if (saved.opened != format_packed) {
        return .{ .size = @min(saved.para, sizes.len - 1), .spacing = @min(saved.byte, spacings.len - 1), .font = @min(saved.percent orelse 0, families.len - 1) };
    }
    const flags = saved.byte;
    return .{
        .size = @min(saved.para & 15, sizes.len - 1),
        .spacing = @min((saved.para >> 4) & 15, spacings.len - 1),
        .font = @min((saved.para >> 8) & 15, families.len - 1),
        .margin = @min((saved.para >> 12) & 15, margins.len - 1),
        .bold = flags & 1 != 0,
        .left_align = flags & 2 != 0,
        .clock = flags & 4 == 0,
        .refresh = flags & 8 != 0,
        .time_left = flags & 16 == 0,
    };
}

pub fn encode(s: Settings) state.State {
    const flags = @as(usize, @intFromBool(s.bold)) | @as(usize, @intFromBool(s.left_align)) << 1 |
        @as(usize, @intFromBool(!s.clock)) << 2 | @as(usize, @intFromBool(s.refresh)) << 3 |
        @as(usize, @intFromBool(!s.time_left)) << 4;
    return .{ .para = s.size | s.spacing << 4 | s.font << 8 | s.margin << 12, .byte = flags, .opened = format_packed };
}

test "settings survive being saved" {
    const s = Settings{ .size = 4, .spacing = 3, .font = 2, .margin = 3, .bold = true, .left_align = true, .clock = false, .refresh = true };
    try std.testing.expectEqual(s, decode(encode(s)));
    try std.testing.expectEqual(Settings{}, decode(encode(.{})));
}

test "settings saved by older versions still load" {
    const s = decode(.{ .para = 3, .byte = 2, .percent = 1, .opened = 1 });
    try std.testing.expectEqual(@as(usize, 3), s.size);
    try std.testing.expectEqual(@as(usize, 2), s.spacing);
    try std.testing.expectEqual(@as(usize, 1), s.font);
    try std.testing.expect(s.clock);
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
    const on = quick_model.Quick{ .airplane = true, .wifi_on = true };
    const off = quick_model.Quick{};
    try std.testing.expect(isOn(shortcuts[0], &on));
    try std.testing.expect(!isOn(shortcuts[0], &off));
    try std.testing.expect(isOn(shortcuts[1], &on));
    try std.testing.expect(!isOn(shortcuts[2], &on));
}
