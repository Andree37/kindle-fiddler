//! Which cached page to overwrite when rendering a new one.
const std = @import("std");

/// Picks a free slot, else one outside the window around `center`.
/// Keeps the page on screen and both of its neighbours.
pub fn victim(pages: [3]i64, center: i64) usize {
    for (pages, 0..) |p, i| {
        if (p < 0) return i;
    }
    for (pages, 0..) |p, i| {
        if (p < center - 1 or p > center + 1) return i;
    }
    for (pages, 0..) |p, i| {
        if (p != center) return i;
    }
    return 0;
}

test "both neighbours stay cached" {
    var pages = [_]i64{ -1, -1, -1 };
    pages[victim(pages, 5)] = 5;
    pages[victim(pages, 5)] = 6;
    pages[victim(pages, 5)] = 4;
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 4) != null);
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 5) != null);
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 6) != null);
}

test "turning forward evicts the page left behind" {
    var pages = [_]i64{ 4, 5, 6 };
    pages[victim(pages, 6)] = 7;
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 4) == null);
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 5) != null);
}
