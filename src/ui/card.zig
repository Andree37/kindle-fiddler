//! A sheet that rises from the bottom, where thumbs are, over a dimmed screen: a
//! title, a line under it, and rows to tap. Tapping above it closes it. The
//! library's book actions and the reader's menu are both sheets.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

const header = 176;
const row_height = 112; // A fingertip and some
const bottom_pad = 40;
const corner = 36;

/// One row. Info rows are facts rather than actions, set lighter; a danger row
/// (removing something) is set bold, so it isn't mistaken for the others.
pub const Row = struct { label: []const u8, quiet: bool = false, danger: bool = false };

pub fn height(rows: usize) u32 {
    return header + @as(u32, @intCast(rows)) * row_height + bottom_pad;
}

pub fn top(rows: usize) u32 {
    return style.screen_height - height(rows);
}

/// Which row a tap lands on: `rows` itself for the sheet's header, null above it.
pub fn hit(x: i32, y: i32, rows: usize) ?usize {
    _ = x;
    const sheet_top: i32 = @intCast(top(rows));
    if (y < sheet_top) return null;
    const first = sheet_top + header;
    if (y < first) return rows;
    const row: usize = @intCast(@divTrunc(y - first, row_height));
    return if (row < rows) row else rows;
}

/// Draws the sheet over `page`, which should hold what's behind it. That gets dimmed,
/// so the sheet is plainly in front.
pub fn render(fonts: Fonts, page: Page, title: []const u8, subtitle: []const u8, rows: []const Row) !void {
    page.dim(0, 0, page.width, page.height);
    const sheet_top = top(rows.len);
    // Rounded at the top; the bottom corners run off the screen
    page.roundRect(0, sheet_top, page.width, height(rows.len) + corner, corner, style.black);
    page.roundRect(0, sheet_top + 2, page.width, height(rows.len) + corner, corner - 1, style.white);
    page.roundRect(page.width / 2 - 36, sheet_top + 18, 72, 8, 4, 0xb0); // Grab bar
    const x: f32 = style.margin;
    const avail: f32 = @floatFromInt(page.width - 2 * style.margin);
    try draw.clipped(fonts.title, page, x, @intCast(sheet_top + 92), title, avail);
    try draw.clipped(fonts.caption, page, x, @intCast(sheet_top + 140), subtitle, avail);
    page.tint(style.margin, sheet_top + 112, @intFromFloat(avail), 44, style.faded);
    for (rows, 0..) |r, i| {
        const y = sheet_top + header + @as(u32, @intCast(i)) * row_height;
        page.fillRect(style.margin, y, page.width - 2 * style.margin, 1, style.rule);
        const font = if (r.danger) fonts.title else fonts.small;
        try draw.clipped(font, page, x, @intCast(y + 70), r.label, avail);
        if (r.quiet) page.tint(style.margin, y + 30, @intFromFloat(avail), 54, style.faded);
    }
}

test "taps map to rows, the header, or nothing above the sheet" {
    const y0: i32 = @intCast(top(3) + header);
    try std.testing.expectEqual(@as(usize, 0), hit(600, y0 + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 2), hit(600, y0 + 2 * row_height + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 3), hit(600, y0 - 20, 3).?);
    try std.testing.expectEqual(@as(usize, 3), hit(600, style.screen_height - 5, 3).?); // Bottom padding
    try std.testing.expect(hit(600, 40, 3) == null);
}

test "the sheet fits on screen with the longest menu" {
    try std.testing.expect(height(6) < style.screen_height / 2 + 300);
}
