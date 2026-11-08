//! The reader's chosen settings: text size, spacing, margins, typeface and toggles,
//! and how they're saved.
const std = @import("std");

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
        return sizes[s.size];
    }

    pub fn lineHeight(s: Settings) i32 {
        return @intFromFloat(sizes[s.size] * spacings[s.spacing]);
    }
};

const format_packed = 2;

/// Settings share the state file format, with everything packed into two numbers.
/// `saved` is a state file's contents: anything with para, byte, percent and opened.
pub fn decode(saved: anytype) Settings {
    if (saved.opened == 0) return .{};
    if (saved.opened != format_packed) {
        return .{ .size = @min(saved.para, sizes.len - 1), .spacing = @min(saved.byte, spacings.len - 1), .font = @min(@as(?u32, saved.percent) orelse 0, families.len - 1) };
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

pub const Packed = struct { para: usize, byte: usize, percent: ?u32 = null, opened: u64 };

pub fn encode(s: Settings) Packed {
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

test "defaults match the original reader" {
    const s = Settings{};
    try std.testing.expectEqual(@as(f32, 46), s.px());
    try std.testing.expectEqual(@as(i32, 62), s.lineHeight());
}
