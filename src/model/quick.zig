//! What the quick panel and status bar show: light, warmth, wireless, battery, time.
const std = @import("std");

pub const max_brightness = 24;

pub const max_warmth = 24;

pub const brightness_step = 2;

pub const Quick = struct {
    brightness: u32 = 0,
    warmth: u32 = 0,
    schedule: bool = false,
    airplane: bool = false,
    syncing: bool = false,
    battery: u32 = 0,
    wifi_on: bool = false,
    wifi_bars: u32 = 0, // 0 to 3
    clock: [40]u8 = undefined,
    clock_len: usize = 0,

    pub fn clockText(q: *const Quick) []const u8 {
        return q.clock[0..q.clock_len];
    }
};

/// Steps brightness, stopping at both ends.
pub fn stepBrightness(level: u32, up: bool) u32 {
    if (up) return @min(level + brightness_step, max_brightness);
    return level -| brightness_step;
}

test "brightness stops at both ends" {
    try std.testing.expectEqual(@as(u32, 24), stepBrightness(23, true));
    try std.testing.expectEqual(@as(u32, 0), stepBrightness(1, false));
    try std.testing.expectEqual(@as(u32, 12), stepBrightness(10, true));
}
