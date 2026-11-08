//! The search sheet's query field, in the space Go To uses for its tabs.
const std = @import("std");
const draw = @import("draw.zig");
const goto = @import("goto.zig");
const style = @import("style.zig");
const text = @import("../book/text.zig");
const Fonts = @import("fonts.zig").Fonts;

const field_top = goto.top + 14;
const field_height = 80;
pub const max_query = 64;

/// Tapping the field brings the keyboard back.
pub fn inField(y: i32) bool {
    return y >= goto.top and y < goto.list_top;
}

/// `found` is the number of results once searched, or null while typing.
pub fn renderField(fonts: Fonts, page: text.Page, query: []const u8, typing: bool, found: ?usize) !void {
    page.fillRect(0, goto.top, page.width, goto.list_top - goto.top, style.white);
    page.fillRect(0, goto.top, page.width, 1, style.rule);
    var count_buf: [32]u8 = undefined;
    const count: []const u8 = if (found) |n|
        (if (n >= 500) "500+ results" else std.fmt.bufPrint(&count_buf, "{d} result{s}", .{ n, if (n == 1) "" else "s" }) catch "")
    else
        "";
    const count_w = if (count.len > 0) try fonts.caption.measure(count) + 32 else 0;
    const width: u32 = page.width - 2 * style.margin - @as(u32, @intFromFloat(count_w));
    draw.box(page, style.margin, field_top, width, field_height);
    const x: f32 = style.margin + 24;
    const baseline: i32 = field_top + 54;
    if (query.len == 0) {
        try fonts.small.draw(page, x, baseline, "Search this book");
        page.tint(style.margin + 8, field_top + 8, width - 16, field_height - 16, 0x90);
    } else {
        try fonts.small.draw(page, x, baseline, query);
    }
    if (typing) {
        const cursor = x + if (query.len > 0) try fonts.small.measure(query) + 4 else 0;
        page.fillRect(@intFromFloat(cursor), field_top + 18, 3, field_height - 36, style.black);
    }
    if (count.len > 0) try fonts.caption.draw(page, @floatFromInt(page.width - style.margin - @as(u32, @intFromFloat(count_w - 32))), baseline, count);
}
