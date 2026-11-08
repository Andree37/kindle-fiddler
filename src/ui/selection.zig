//! Text selection on a page: which words a finger covers, and how they look.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const text = @import("../layout/text.zig");

/// The word exactly under a point, if any.
pub fn wordUnder(words: []const text.Word, x: i32, y: i32) ?text.Word {
    for (words) |w| {
        if (x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h) return w;
    }
    return null;
}

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

const underline = 5;
const handle_radius = 13;
const handle_reach = 30; // Above the first line and below the last
pub const grab_distance = 70; // How near a finger counts as grabbing a handle

/// A handle at each end of the selection, like the marks in the margin of a proof.
pub const Handle = struct { x: i32, y: i32 };

pub fn startHandle(selected: []const text.Word) Handle {
    const w = selected[0];
    return .{ .x = w.x - 3, .y = w.y - handle_reach + @divTrunc(w.h, 4) };
}

pub fn endHandle(selected: []const text.Word) Handle {
    const w = selected[selected.len - 1];
    return .{ .x = w.x + w.w + 3, .y = w.y + w.h + handle_reach - @divTrunc(w.h, 4) };
}

pub fn nearHandle(h: Handle, x: i32, y: i32) bool {
    return @abs(x - h.x) < grab_distance and @abs(y - h.y) < grab_distance;
}

/// Underlines the selected words line by line, with a handle at each end.
pub fn draw(page: Page, selected: []const text.Word) void {
    var i: usize = 0;
    while (i < selected.len) {
        var j = i;
        while (j + 1 < selected.len and selected[j + 1].y == selected[i].y) j += 1;
        const last = selected[j];
        const left = selected[i].x;
        const right = last.x + last.w;
        page.fillRect(@intCast(left), @intCast(selected[i].y + selected[i].h - underline - 2), @intCast(right - left), underline, 0x00);
        i = j + 1;
    }
    const first = selected[0];
    const start = startHandle(selected);
    page.fillRect(@intCast(start.x - 2), @intCast(start.y), 4, @intCast(first.y + first.h - start.y), 0x00);
    page.disc(start.x, start.y, handle_radius, 0, 0x00);
    const final = selected[selected.len - 1];
    const end = endHandle(selected);
    page.fillRect(@intCast(end.x - 2), @intCast(final.y), 4, @intCast(end.y - final.y), 0x00);
    page.disc(end.x, end.y, handle_radius, 0, 0x00);
}

pub const Band = struct { top: u32, height: u32 };

/// Rows the selection and its handles touch.
pub fn band(selected: []const text.Word) Band {
    const margin = handle_reach + handle_radius;
    const top = @max(selected[0].y - margin, 0);
    const last = selected[selected.len - 1];
    return .{ .top = @intCast(top), .height = @intCast(last.y + last.h + margin - top) };
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

test "band includes the handles" {
    const words = [_]text.Word{ word(100, 100), word(100, 160) };
    const b = band(&words);
    try std.testing.expect(b.top < 100);
    try std.testing.expect(b.top + b.height > 200);
}

test "a finger near a handle grabs it" {
    const words = [_]text.Word{ word(100, 100), word(200, 100) };
    const end = endHandle(&words);
    try std.testing.expect(nearHandle(end, end.x + 20, end.y - 20));
    try std.testing.expect(!nearHandle(end, 600, 600));
}
