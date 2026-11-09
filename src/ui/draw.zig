//! Small drawing pieces several screens use.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

/// Text centred on `center_x`.
pub fn centered(font: *Font, page: Page, center_x: f32, y: i32, s: []const u8) !void {
    try font.draw(page, center_x - try font.measure(s) / 2, y, s);
}

pub fn clipped(font: *Font, page: Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
    const w = try font.measure(s);
    if (w <= avail) return font.draw(page, x, y, s);
    const dots = "...";
    const cut = try font.fit(s, avail - try font.measure(dots));
    var buf: [256]u8 = undefined;
    const part = std.mem.trimEnd(u8, s[0..@min(cut, buf.len - dots.len)], " ");
    @memcpy(buf[0..part.len], part);
    @memcpy(buf[part.len..][0..dots.len], dots);
    try font.draw(page, x, y, buf[0 .. part.len + dots.len]);
}

/// A white box with a thin black outline.
pub fn box(page: Page, x: u32, y: u32, w: u32, h: u32) void {
    page.fillRect(x, y, w, h, style.black);
    page.fillRect(x + style.border, y + style.border, w - 2 * style.border, h - 2 * style.border, style.white);
}

pub const Align = enum { left, center };

/// One option in a row of options: bold and underlined at `underline_y` when chosen.
/// `x` is its left edge or its centre.
pub fn choice(fonts: Fonts, page: Page, x: f32, align_to: Align, y: i32, label: []const u8, chosen: bool, underline_y: u32) !void {
    const font = if (chosen) fonts.title else fonts.small;
    const w = try font.measure(label);
    const left = if (align_to == .center) x - w / 2 else x;
    try font.draw(page, left, y, label);
    if (chosen) page.fillRect(@intFromFloat(left), underline_y, @intFromFloat(w), style.underline, style.black);

}

/// The "1 of 4" row with back and forward arrows, under a list shown a page at a time.
pub const Pager = struct {
    top: u32,
    bottom: u32,
    reach: u32 = 0, // Taps count down to here, when that's past `bottom`

    const button = 200;
    const prev_left = 340;
    const next_left = 732;

    pub const Hit = enum { prev, next };

    pub fn hit(p: Pager, x: i32, y: i32) ?Hit {
        if (y < p.top or y >= @max(p.bottom, p.reach)) return null;
        if (x >= prev_left and x < prev_left + button) return .prev;
        if (x >= next_left and x < next_left + button) return .next;
        return null;
    }

    pub fn render(p: Pager, fonts: Fonts, page: Page, index: usize, pages: usize) !void {
        const y: i32 = @intCast((p.top + p.bottom) / 2 + 12);
        var label: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&label, "{d} of {d}", .{ index + 1, pages }) catch "";
        try centered(fonts.small, page, @floatFromInt(page.width / 2), y, count);
        const mid: f32 = @floatFromInt(y - 11);
        const prev_x: f32 = prev_left + button / 2;
        const next_x: f32 = next_left + button / 2;
        page.stroke(prev_x + 9, mid - 18, prev_x - 9, mid, 4);
        page.stroke(prev_x - 9, mid, prev_x + 9, mid + 18, 4);
        page.stroke(next_x - 9, mid - 18, next_x + 9, mid, 4);
        page.stroke(next_x + 9, mid, next_x - 9, mid + 18, 4);
        // Faded when there's nowhere to go.
        if (index == 0) page.tint(prev_left, p.top, button, p.bottom - p.top, 0xc8);
        if (index + 1 >= pages) page.tint(next_left, p.top, button, p.bottom - p.top, 0xc8);
    }
};

/// Where every list's pager sits: near the bottom, taking taps right to the edge,
/// so a thumb reaching low still turns the page.
pub const bottom_pager = Pager{ .top = 1530, .bottom = 1650, .reach = style.screen_height };

test "the shared pager takes taps to the bottom edge" {
    try std.testing.expectEqual(Pager.Hit.next, bottom_pager.hit(800, 1690).?);
    try std.testing.expect(bottom_pager.hit(800, 1500) == null);
}

test "pager arrows sit either side of the count" {
    const p = Pager{ .top = 100, .bottom = 200 };
    try std.testing.expectEqual(Pager.Hit.prev, p.hit(400, 150).?);
    try std.testing.expectEqual(Pager.Hit.next, p.hit(800, 150).?);
    try std.testing.expect(p.hit(600, 150) == null);
    try std.testing.expect(p.hit(400, 250) == null);
}
