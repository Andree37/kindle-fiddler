//! A one-line text field under the toolbar, in the space Go To uses for its tabs.
//! Search and Go to page type into it.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const goto = @import("goto.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

const field_top = goto.top + 14;
const field_height = 80;

/// Tapping the field brings the keyboard back.
pub fn inField(y: i32) bool {
    return y >= goto.top and y < goto.list_top;
}

/// The field: `value` as typed, or `placeholder` while empty, with a cursor while
/// typing and an optional `note` on the right, like a result count.
pub fn render(fonts: Fonts, page: Page, value: []const u8, placeholder: []const u8, typing: bool, note: []const u8) !void {
    page.fillRect(0, goto.top, page.width, goto.list_top - goto.top, style.white);
    page.fillRect(0, goto.top, page.width, 1, style.rule);
    const note_w = if (note.len > 0) try fonts.caption.measure(note) + 32 else 0;
    const width: u32 = page.width - 2 * style.margin - @as(u32, @intFromFloat(note_w));
    draw.box(page, style.margin, field_top, width, field_height);
    const x: f32 = style.margin + 24;
    const baseline: i32 = field_top + 54;
    if (value.len == 0) {
        try fonts.small.draw(page, x, baseline, placeholder);
        page.tint(style.margin + 8, field_top + 8, width - 16, field_height - 16, 0x90);
    } else {
        try fonts.small.draw(page, x, baseline, value);
    }
    if (typing) {
        const cursor = x + if (value.len > 0) try fonts.small.measure(value) + 4 else 0;
        page.fillRect(@intFromFloat(cursor), field_top + 18, 3, field_height - 36, style.black);
    }
    if (note.len > 0) try fonts.caption.draw(page, @floatFromInt(page.width - style.margin - @as(u32, @intFromFloat(note_w - 32))), baseline, note);
}
