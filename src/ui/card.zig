//! A card in the middle of the screen: a title, a line under it, and rows to tap.
//! The library's book actions and the reader's menu are both cards.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const left = 136;
pub const width = 1000;
const header = 196;
const row_height = 112;

/// One row. Quiet rows (like Cancel, or details that aren't actions) use the lighter font.
pub const Row = struct { label: []const u8, quiet: bool = false };

pub fn height(rows: usize) u32 {
    return header + @as(u32, @intCast(rows)) * row_height;
}

pub fn top(rows: usize) u32 {
    return (style.screen_height - height(rows)) / 2;
}

/// Which row a tap lands on: `rows` itself for the card's header, null outside the card.
pub fn hit(x: i32, y: i32, rows: usize) ?usize {
    const card_top: i32 = @intCast(top(rows));
    if (x < left or x >= left + width or y < card_top) return null;
    const first = card_top + header;
    if (y >= first + @as(i32, @intCast(rows)) * row_height) return null;
    if (y < first) return rows;
    return @intCast(@divTrunc(y - first, row_height));
}

pub fn render(fonts: Fonts, page: Page, title: []const u8, subtitle: []const u8, rows: []const Row) !void {
    const card_top = top(rows.len);
    const h = height(rows.len);
    page.fillRect(left - 6, card_top - 6, width + 12, h + 12, style.white);
    draw.box(page, left, card_top, width, h);
    const x: f32 = left + 48;
    const avail: f32 = width - 96;
    try draw.clipped(fonts.title, page, x, @intCast(card_top + 76), title, avail);
    try draw.clipped(fonts.caption, page, x, @intCast(card_top + 128), subtitle, avail);
    page.tint(left + 48, card_top + 100, width - 96, 44, style.faded);
    for (rows, 0..) |r, i| {
        const y = card_top + header + @as(u32, @intCast(i)) * row_height;
        page.fillRect(left + 3, y, width - 6, 1, style.rule);
        const font = if (r.quiet) fonts.small else fonts.title;
        try draw.clipped(font, page, x, @intCast(y + 70), r.label, avail);
    }
}

test "taps map to rows, the header, or nothing" {
    const y0: i32 = @intCast(top(3) + header);
    try std.testing.expectEqual(@as(usize, 0), hit(600, y0 + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 2), hit(600, y0 + 2 * row_height + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 3), hit(600, y0 - 20, 3).?);
    try std.testing.expect(hit(50, y0, 3) == null);
    try std.testing.expect(hit(600, 40, 3) == null);
}
