//! Small drawing pieces several screens use.
const std = @import("std");
const text = @import("../book/text.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

/// Text centred on `center_x`.
pub fn centered(font: *text.Font, page: text.Page, center_x: f32, y: i32, s: []const u8) !void {
    try font.draw(page, center_x - try font.measure(s) / 2, y, s);
}

/// A white box with a thin black outline.
pub fn box(page: text.Page, x: u32, y: u32, w: u32, h: u32) void {
    page.fillRect(x, y, w, h, style.black);
    page.fillRect(x + style.border, y + style.border, w - 2 * style.border, h - 2 * style.border, style.white);
}

pub const Align = enum { left, center };

/// One option in a row of options: bold and underlined at `underline_y` when chosen.
/// `x` is its left edge or its centre.
pub fn choice(fonts: Fonts, page: text.Page, x: f32, align_to: Align, y: i32, label: []const u8, chosen: bool, underline_y: u32) !void {
    const font = if (chosen) fonts.title else fonts.small;
    const w = try font.measure(label);
    const left = if (align_to == .center) x - w / 2 else x;
    try font.draw(page, left, y, label);
    if (chosen) page.fillRect(@intFromFloat(left), underline_y, @intFromFloat(w), style.underline, style.black);

}
