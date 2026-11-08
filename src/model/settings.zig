//! The reader's chosen settings: text size, spacing, margins, typeface and toggles,
//! and how they're saved.
const std = @import("std");
const check = @import("../base/check.zig");

/// The typefaces offered, by name. kindle/fonts.zig has their files, in the same order.
pub const families = [_][]const u8{ "Ember", "Bookerly", "Baskerville", "Serif" };

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
        s.checkSteps();
        return sizes[s.size];
    }

    pub fn lineHeight(s: Settings) i32 {
        s.checkSteps();
        return @intFromFloat(sizes[s.size] * spacings[s.spacing]);
    }

    /// Parsing clamps every value, so an index out of range is a bug of ours.
    fn checkSteps(s: Settings) void {
        check.that(s.size < sizes.len and s.spacing < spacings.len and s.margin < margins.len and s.font < families.len, "settings are within their steps");
    }
};

/// The settings file: one "name value" per line, for example "font Bookerly" or
/// "bold off". Lines it doesn't know are skipped, and every value is checked.
pub fn parse(content: []const u8) Settings {
    if (looksOld(content)) return fromOldFile(content);
    var s = Settings{};
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const name = words.next() orelse continue;
        const value = words.next() orelse continue;
        if (std.mem.eql(u8, name, "size")) s.size = step(value, sizes.len, s.size);
        if (std.mem.eql(u8, name, "spacing")) s.spacing = step(value, spacings.len, s.spacing);
        if (std.mem.eql(u8, name, "margins")) s.margin = step(value, margins.len, s.margin);
        if (std.mem.eql(u8, name, "font")) s.font = familyNamed(value) orelse s.font;
        if (std.mem.eql(u8, name, "bold")) s.bold = isOn(value, s.bold);
        if (std.mem.eql(u8, name, "justify")) s.left_align = !isOn(value, !s.left_align);
        if (std.mem.eql(u8, name, "clock")) s.clock = isOn(value, s.clock);
        if (std.mem.eql(u8, name, "refresh")) s.refresh = isOn(value, s.refresh);
        if (std.mem.eql(u8, name, "time-left")) s.time_left = isOn(value, s.time_left);
    }
    return s;
}

pub fn format(buf: []u8, s: Settings) []const u8 {
    return std.fmt.bufPrint(buf,
        \\size {d}
        \\spacing {d}
        \\margins {d}
        \\font {s}
        \\bold {s}
        \\justify {s}
        \\clock {s}
        \\refresh {s}
        \\time-left {s}
        \\
    , .{ s.size, s.spacing, s.margin, families[s.font], onOff(s.bold), onOff(!s.left_align), onOff(s.clock), onOff(s.refresh), onOff(s.time_left) }) catch "";
}

fn step(value: []const u8, count: usize, fallback: usize) usize {
    const n = std.fmt.parseInt(usize, value, 10) catch return fallback;
    return if (n < count) n else fallback;
}

fn familyNamed(name: []const u8) ?usize {
    for (families, 0..) |f, i| {
        if (std.mem.eql(u8, f, name)) return i;
    }
    return null;
}

fn isOn(value: []const u8, fallback: bool) bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return fallback;
}

fn onOff(on: bool) []const u8 {
    return if (on) "on" else "off";
}

/// Earlier versions saved settings as numbers in the reading-position file's shape:
/// "a b c d". They're read once, then saved again in the format above.
fn looksOld(content: []const u8) bool {
    const first = std.mem.trimStart(u8, content, " \n");
    return first.len > 0 and std.ascii.isDigit(first[0]);
}

fn fromOldFile(content: []const u8) Settings {
    var numbers: [4]usize = @splat(0);
    var words = std.mem.tokenizeAny(u8, content, " \n");
    for (&numbers) |*n| n.* = std.fmt.parseInt(usize, words.next() orelse break, 10) catch 0;
    const a = numbers[0];
    const b = numbers[1];
    const version = numbers[3];
    if (version == 0) return .{};
    if (version != 2) {
        // First version: size, spacing, font index.
        return .{ .size = @min(a, sizes.len - 1), .spacing = @min(b, spacings.len - 1), .font = @min(numbers[2], families.len - 1) };
    }
    // Second version: size, spacing, font and margin in 4 bits each, toggles as bits.
    return .{
        .size = @min(a & 15, sizes.len - 1),
        .spacing = @min((a >> 4) & 15, spacings.len - 1),
        .font = @min((a >> 8) & 15, families.len - 1),
        .margin = @min((a >> 12) & 15, margins.len - 1),
        .bold = b & 1 != 0,
        .left_align = b & 2 != 0,
        .clock = b & 4 == 0,
        .refresh = b & 8 != 0,
        .time_left = b & 16 == 0,
    };
}

test "settings survive being saved" {
    var buf: [256]u8 = undefined;
    const s = Settings{ .size = 4, .spacing = 3, .font = 2, .margin = 3, .bold = true, .left_align = true, .clock = false, .refresh = true, .time_left = false };
    try std.testing.expectEqual(s, parse(format(&buf, s)));
    try std.testing.expectEqual(Settings{}, parse(format(&buf, .{})));
    try std.testing.expect(std.mem.indexOf(u8, format(&buf, s), "font Baskerville\n") != null);
}

test "bad or unknown lines change nothing" {
    const s = parse("size 99\nfont Comic\nbold maybe\ncolour red\nspacing 2\n");
    try std.testing.expectEqual(Settings{ .spacing = 2 }, s);
}

test "settings saved by older versions still load" {
    const first = parse("3 2 1 1\n");
    try std.testing.expectEqual(@as(usize, 3), first.size);
    try std.testing.expectEqual(@as(usize, 2), first.spacing);
    try std.testing.expectEqual(@as(usize, 1), first.font);
    try std.testing.expect(first.clock);
    // The second version, as on the device today: size 3, spacing 1, no flags.
    const second = parse("19 0 0 2\n");
    try std.testing.expectEqual(@as(usize, 3), second.size);
    try std.testing.expectEqual(@as(usize, 1), second.spacing);
    try std.testing.expectEqual(@as(usize, 0), second.margin);
    try std.testing.expect(second.clock and second.time_left);
}

test "defaults match the original reader" {
    const s = Settings{};
    try std.testing.expectEqual(@as(f32, 46), s.px());
    try std.testing.expectEqual(@as(i32, 62), s.lineHeight());
}
