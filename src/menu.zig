//! Bar shown over a book: tap the top of a page to open it.
const std = @import("std");
const library = @import("library.zig");
const state = @import("state.zig");
const text = @import("text.zig");

pub const tap_zone = 150; // Top of the page, which opens the bar
pub const height = 312;
const first_row = 160;

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

pub const Hit = enum { none, close, library, kindle, smaller, larger, tighter, looser };

const Button = struct { hit: Hit, label: []const u8, left: i32, right: i32 };
const buttons = [_]Button{
    .{ .hit = .smaller, .label = "-", .left = 300, .right = 420 },
    .{ .hit = .larger, .label = "+", .left = 440, .right = 560 },
    .{ .hit = .tighter, .label = "-", .left = 880, .right = 1000 },
    .{ .hit = .looser, .label = "+", .left = 1020, .right = 1140 },
};

pub fn hit(x: i32, y: i32, width: i32) Hit {
    if (y >= height) return .close;
    if (y < first_row) {
        if (x < 300) return .library;
        if (x >= width - 300) return .kindle;
        return .none;
    }
    for (buttons) |b| {
        if (x >= b.left and x < b.right) return b.hit;
    }
    return .none;
}

pub fn render(fonts: library.Fonts, page: text.Page, title: []const u8) !void {
    page.fillRect(0, 0, page.width, height, 0xff);
    page.fillRect(0, first_row, page.width, 2, 0x80);
    page.fillRect(0, height - 4, page.width, 4, 0x00);

    try fonts.title.draw(page, 60, 100, "< Library");
    try library.drawClipped(fonts.small, page, 320, 100, title, 620);
    try fonts.title.draw(page, @as(f32, @floatFromInt(page.width)) - 200, 100, "Kindle");

    try fonts.small.draw(page, 60, 250, "Text size");
    try fonts.small.draw(page, 640, 250, "Spacing");
    for (buttons) |b| {
        const left: u32 = @intCast(b.left);
        const right: u32 = @intCast(b.right);
        page.fillRect(left, 190, right - left, 100, 0xe0);
        try fonts.title.draw(page, @floatFromInt(left + 48), 254, b.label);
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

test "bar buttons map to actions" {
    try std.testing.expectEqual(Hit.library, hit(100, 80, 1272));
    try std.testing.expectEqual(Hit.kindle, hit(1100, 80, 1272));
    try std.testing.expectEqual(Hit.none, hit(600, 80, 1272));
    try std.testing.expectEqual(Hit.smaller, hit(350, 240, 1272));
    try std.testing.expectEqual(Hit.larger, hit(500, 240, 1272));
    try std.testing.expectEqual(Hit.tighter, hit(900, 240, 1272));
    try std.testing.expectEqual(Hit.looser, hit(1100, 240, 1272));
    try std.testing.expectEqual(Hit.close, hit(600, 800, 1272));
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
