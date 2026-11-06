//! The one slider used everywhere. Pure black and white with pixel-aligned edges,
//! so it looks the same at rest and under the fast waveform used while dragging.
const std = @import("std");
const text = @import("text.zig");

pub const Slider = struct { left: u32, right: u32, y: u32 };

const half_height = 7;
const outline = 2;
const knob_outer = 27;
const knob_inner = 21;

/// Knob position for `value` out of `max`.
pub fn knobAt(s: Slider, value: u32, max: u32) u32 {
    if (max == 0) return s.left;
    const span = s.right - s.left;
    return s.left + @min(value, max) * span / max;
}

/// Nearest value out of `max` for a finger at `x`.
pub fn valueAt(s: Slider, x: i32, max: u32) u32 {
    const left: i32 = @intCast(s.left);
    const span: i32 = @intCast(s.right - s.left);
    const at: u32 = @intCast(std.math.clamp(x - left, 0, span));
    return (at * max + @as(u32, @intCast(span)) / 2) / @as(u32, @intCast(span));
}

/// Marks each step, for sliders with only a few positions.
pub fn drawTicks(page: text.Page, s: Slider, max: u32) void {
    var i: u32 = 0;
    while (i <= max) : (i += 1) {
        const x = knobAt(s, i, max);
        page.fillRect(x - 1, s.y + half_height + 8, 3, 10, 0x00);
    }
}

pub fn draw(page: text.Page, s: Slider, knob: u32) void {
    const width = s.right - s.left;
    const top = s.y - half_height;
    const height = 2 * half_height;
    page.fillRect(s.left, top, width, height, 0x00);
    page.fillRect(s.left + outline, top + outline, width - 2 * outline, height - 2 * outline, 0xff);
    if (knob > s.left) page.fillRect(s.left, top, knob - s.left, height, 0x00);
    const x: i32 = @intCast(knob);
    const y: i32 = @intCast(s.y);
    page.disc(x, y, knob_outer + 3, 0, 0xff); // A clear gap around the knob
    page.disc(x, y, knob_outer, 0, 0x00);
    page.disc(x, y, knob_inner, 0, 0xff);
}

test "value and knob agree" {
    const s = Slider{ .left = 100, .right = 1100, .y = 50 };
    try std.testing.expectEqual(@as(u32, 100), knobAt(s, 0, 24));
    try std.testing.expectEqual(@as(u32, 1100), knobAt(s, 24, 24));
    try std.testing.expectEqual(@as(u32, 600), knobAt(s, 12, 24));
    try std.testing.expectEqual(@as(u32, 0), valueAt(s, 0, 24));
    try std.testing.expectEqual(@as(u32, 24), valueAt(s, 2000, 24));
    try std.testing.expectEqual(@as(u32, 12), valueAt(s, 600, 24));
}

test "small ranges snap to the nearest step" {
    const s = Slider{ .left = 0, .right = 900, .y = 50 };
    try std.testing.expectEqual(@as(u32, 1), valueAt(s, 260, 3));
    try std.testing.expectEqual(@as(u32, 2), valueAt(s, 500, 3));
}
