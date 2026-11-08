//! An on-screen keyboard along the bottom of the screen. Letters and digits only:
//! search ignores case and accents, so nothing else is needed.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

const rows = [_][]const u8{ "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm" };
const key_width = 116;
const key_height = 112;
const gap = 8;
const row_step = key_height + gap;
pub const top = style.screen_height - 5 * row_step - 16;

pub const Key = union(enum) { char: u8, backspace, space, enter };

fn rowLeft(row: usize) i32 {
    const n: i32 = @intCast(rows[row].len);
    const width = n * (key_width + gap) - gap;
    return @divTrunc(style.screen_width - width, 2);
}

/// The special keys: backspace beside the last letter row, then space and Search.
const backspace_x = style.screen_width - 16 - 180;
const space_left = 140;
const space_width = 640;
const enter_left = space_left + space_width + gap * 3;
const enter_width = 300;

pub fn hit(x: i32, y: i32) ?Key {
    if (y < top) return null;
    const row: usize = @intCast(@divTrunc(y - top, row_step));
    if (row < rows.len) {
        if (row == 3 and x >= backspace_x) return .backspace;
        const left = rowLeft(row);
        if (x < left) return null;
        const col: usize = @intCast(@divTrunc(x - left, key_width + gap));
        return if (col < rows[row].len) .{ .char = rows[row][col] } else null;
    }
    if (row == rows.len) {
        if (x >= space_left and x < space_left + space_width) return .space;
        if (x >= enter_left and x < enter_left + enter_width) return .enter;
    }
    return null;
}

fn key(fonts: Fonts, page: Page, x: i32, y: u32, w: u32, label: []const u8) !void {
    draw.box(page, @intCast(x), y, w, key_height);
    try draw.centered(fonts.small, page, @floatFromInt(x + @as(i32, @intCast(w / 2))), @intCast(y + 72), label);
}

pub fn render(fonts: Fonts, page: Page) !void {
    page.fillRect(0, top - 16, page.width, page.height - (top - 16), style.white);
    page.fillRect(0, top - 16, page.width, 1, style.rule);
    for (rows, 0..) |r, row| {
        const y: u32 = top + @as(u32, @intCast(row)) * row_step;
        for (r, 0..) |c, col| {
            const x = rowLeft(row) + @as(i32, @intCast(col)) * (key_width + gap);
            try key(fonts, page, x, y, key_width, &.{c});
        }
    }
    const last: u32 = top + 3 * row_step;
    try key(fonts, page, backspace_x, last, 180, "Delete");
    const bottom: u32 = top + 4 * row_step;
    try key(fonts, page, space_left, bottom, space_width, "space");
    // The main key: drawn like the others, then inverted to white on black.
    page.fillRect(enter_left, bottom, enter_width, key_height, style.white);
    try draw.centered(fonts.title, page, @floatFromInt(enter_left + enter_width / 2), @intCast(bottom + 72), "Search");
    page.invert(enter_left, bottom, enter_width, key_height);
}

test "keys map to letters, and the special keys answer" {
    try std.testing.expectEqual(Key{ .char = 'q' }, hit(rowLeft(1) + 10, top + row_step + 10).?);
    try std.testing.expectEqual(Key{ .char = '0' }, hit(rowLeft(0) + 9 * (key_width + gap) + 10, top + 10).?);
    try std.testing.expectEqual(Key{ .char = 'm' }, hit(rowLeft(3) + 6 * (key_width + gap) + 10, top + 3 * row_step + 10).?);
    try std.testing.expectEqual(Key.backspace, hit(backspace_x + 20, top + 3 * row_step + 10).?);
    try std.testing.expectEqual(Key.space, hit(space_left + 100, top + 4 * row_step + 10).?);
    try std.testing.expectEqual(Key.enter, hit(enter_left + 100, top + 4 * row_step + 10).?);
    try std.testing.expect(hit(600, top - 50) == null);
}

test "the keyboard fits, with backspace clear of the letters" {
    try std.testing.expect(top + 5 * row_step <= style.screen_height);
    try std.testing.expect(rowLeft(3) + 7 * (key_width + gap) < backspace_x);
}
