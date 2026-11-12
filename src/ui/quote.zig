//! The lock screen with one of the book's highlights: the words in the reader's own
//! typeface, centred on the page, and under a short rule the book they're from.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const Fonts = @import("fonts.zig").Fonts;
const draw = @import("draw.zig");
const style = @import("style.zig");

const side = 140; // Wider margins than a page: it's read at a glance
const max_lines = 14;

/// Draws `text` from `title` by `author` over the whole of `page`.
pub fn render(fonts: Fonts, body: *Font, page: Page, text: []const u8, title: []const u8, author: []const u8) !void {
    page.fillRect(0, 0, page.width, page.height, style.white);
    const avail: f32 = @floatFromInt(page.width - 2 * side);

    // Break the lines first, to centre the block
    var starts: [max_lines][]const u8 = undefined;
    var n: usize = 0;
    var rest = std.mem.trim(u8, text, " ");
    while (rest.len > 0 and n < max_lines) : (n += 1) {
        const end = try draw.lineEnd(body, rest, avail);
        starts[n] = rest[0..end];
        rest = std.mem.trimStart(u8, rest[end..], " ");
    }
    const line: i32 = body.line_height;
    const block = @as(i32, @intCast(n)) * line + 220; // The lines, the rule and the book
    var y: i32 = @divTrunc(@as(i32, @intCast(page.height)) - block, 2) + body.ascent;
    for (starts[0..n]) |l| {
        try body.draw(page, side, y, l);
        y += line;
    }

    y += 64;
    page.fillRect(side, @intCast(y - 36), 96, 3, style.black);
    try draw.clipped(fonts.title, page, side, y + 20, title, avail);
    if (author.len > 0) try draw.clipped(fonts.caption, page, side, y + 66, author, avail);
}
