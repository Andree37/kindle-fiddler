//! Tells a holding thumb from a tap by where it lands.
const std = @import("std");

const bottom_strip = 120; // Full width, along the bottom edge
const corner_width = 300; // Bottom corners, where thumbs sit higher
const corner_height = 250;

pub fn isGrip(x: i32, y: i32, width: i32, height: i32) bool {
    if (y >= height - bottom_strip) return true;
    if (y < height - corner_height) return false;
    return x < corner_width or x >= width - corner_width;
}

test "measured thumb positions are grips" {
    try std.testing.expect(isGrip(153, 1531, 1272, 1696));
    try std.testing.expect(isGrip(1119, 1586, 1272, 1696));
    try std.testing.expect(isGrip(683, 1630, 1272, 1696));
    try std.testing.expect(isGrip(278, 1695, 1272, 1696));
}

test "measured taps still turn pages" {
    try std.testing.expect(!isGrip(456, 970, 1272, 1696));
    try std.testing.expect(!isGrip(1106, 1179, 1272, 1696));
    try std.testing.expect(!isGrip(636, 1500, 1272, 1696));
}
