//! Tells a holding thumb from a tap by where it lands.
const std = @import("std");

const bottom_strip = 120; // Full width, along the bottom edge
const corner_width = 300; // Bottom corners, where thumbs sit higher
const corner_height = 250;

pub const top_zone = 150; // Top edge: taps wait for lift here, so a drag can start
const pull_distance = 80;

/// True once a touch that began at the top has dragged far enough down.
pub fn isPull(start_y: i32, y: i32) bool {
    return y - start_y >= pull_distance;
}

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

test "dragging down from the top counts as a pull" {
    try std.testing.expect(!isPull(40, 100));
    try std.testing.expect(isPull(40, 120));
    try std.testing.expect(!isPull(100, 60));
}
