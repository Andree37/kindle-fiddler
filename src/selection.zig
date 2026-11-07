//! Text selection on a page: which words a finger covers, and how they look.
const std = @import("std");
const text = @import("text.zig");

/// The word under or nearest to a point. Lines match by height first.
pub fn wordAt(words: []const text.Word, x: i32, y: i32) ?usize {
    var best: ?usize = null;
    var best_row: i32 = std.math.maxInt(i32);
    var best_col: i32 = std.math.maxInt(i32);
    for (words, 0..) |w, i| {
        const row = if (y < w.y) w.y - y else if (y >= w.y + w.h) y - (w.y + w.h) + 1 else 0;
        const col = if (x < w.x) w.x - x else if (x >= w.x + w.w) x - (w.x + w.w) + 1 else 0;
        if (row < best_row or (row == best_row and col < best_col)) {
            best = i;
            best_row = row;
            best_col = col;
        }
    }
    return best;
}

/// Inverts the selected words, joining the gaps along each line.
pub fn draw(page: text.Page, selected: []const text.Word) void {
    var i: usize = 0;
    while (i < selected.len) {
        var j = i;
        var right = selected[i].x + selected[i].w;
        while (j + 1 < selected.len and selected[j + 1].y == selected[i].y) {
            j += 1;
            right = selected[j].x + selected[j].w;
        }
        const left = selected[i].x;
        page.invert(@intCast(left - 4), @intCast(selected[i].y), @intCast(right - left + 8), @intCast(selected[i].h));
        i = j + 1;
    }
}

pub const Band = struct { top: u32, height: u32 };

/// Rows the selection touches.
pub fn band(selected: []const text.Word) Band {
    const top = selected[0].y;
    const last = selected[selected.len - 1];
    return .{ .top = @intCast(top), .height = @intCast(last.y + last.h - top) };
}

fn word(x: i32, y: i32) text.Word {
    return .{ .x = x, .y = y, .w = 50, .h = 40, .para = 0, .start = 0, .end = 1 };
}

test "finds the word under a finger" {
    const words = [_]text.Word{ word(100, 100), word(200, 100), word(100, 160), word(200, 160) };
    try std.testing.expectEqual(@as(usize, 1), wordAt(&words, 220, 120).?);
    try std.testing.expectEqual(@as(usize, 2), wordAt(&words, 110, 170).?);
}

test "a finger between lines or past the edge snaps to the nearest word" {
    const words = [_]text.Word{ word(100, 100), word(200, 100), word(100, 160), word(200, 160) };
    try std.testing.expectEqual(@as(usize, 1), wordAt(&words, 900, 110).?);
    try std.testing.expectEqual(@as(usize, 0), wordAt(&words, 10, 10).?);
}

test "no words means no selection" {
    try std.testing.expect(wordAt(&.{}, 10, 10) == null);
}

test "band covers first to last line" {
    const words = [_]text.Word{ word(100, 100), word(100, 160) };
    const b = band(&words);
    try std.testing.expectEqual(@as(u32, 100), b.top);
    try std.testing.expectEqual(@as(u32, 100), b.height);
}
