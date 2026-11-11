//! A sheet of words that rises from the bottom over the dimmed page: a title, a line
//! under it, then headings and wrapped text. As tall as what it holds, up to most of
//! the screen. Any tap closes it. The recap and a character's page are these.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

const corner = 36;
const header = 190; // Grab bar, title and the line under it
const line_step = 46;
const heading_gap = 30; // Above a heading, setting sections apart
const bottom_pad = 60;
const paragraph_gap = 16;
pub const max_height = style.screen_height - 260;

pub const Kind = enum {
    heading, // Small and gray: "Last seen"
    text, // Wrapped body text
    note, // A caption over the text after it: "Page 120"
};

pub const Block = struct { kind: Kind, text: []const u8 };

const Writer = struct {
    fonts: Fonts,
    page: ?Page, // Null while only measuring
    y: i32,
    bottom: i32,
    after_text: bool = false, // The last block was text: the next one is a new paragraph

    /// Whether a line can sit on baseline `y`: measuring and drawing agree on this.
    fn room(w: *const Writer) bool {
        return w.y <= w.bottom;
    }

    fn block(w: *Writer, b: Block) !void {
        const avail: f32 = @floatFromInt(style.screen_width - 2 * style.margin);
        switch (b.kind) {
            .heading, .note => {
                w.y += if (b.kind == .heading) heading_gap else 10;
                if (!w.room()) return;
                if (w.page) |page| {
                    try w.fonts.caption.draw(page, style.margin, w.y, b.text);
                    page.tint(style.margin, @intCast(w.y - 28), @intFromFloat(avail), 36, style.faded);
                }
                w.y += line_step - 6;
            },
            .text => {
                if (w.after_text) w.y += paragraph_gap;
                var rest = std.mem.trim(u8, b.text, " ");
                while (rest.len > 0 and w.room()) {
                    const n = try draw.wrapEnd(w.fonts.small, rest, avail);
                    if (w.page) |page| try w.fonts.small.draw(page, style.margin, w.y, rest[0..n]);
                    rest = std.mem.trimStart(u8, rest[n..], " ");
                    w.y += line_step;
                }
            },
        }
        w.after_text = b.kind == .text;
    }
};

/// How tall the sheet is for these blocks.
pub fn height(fonts: Fonts, blocks: []const Block) !u32 {
    var w = Writer{ .fonts = fonts, .page = null, .y = header + line_step - 10, .bottom = max_height - bottom_pad };
    for (blocks) |b| try w.block(b);
    return @min(max_height, @as(u32, @intCast(w.y)) - line_step + bottom_pad);
}

pub fn top(fonts: Fonts, blocks: []const Block) !u32 {
    return style.screen_height - try height(fonts, blocks);
}

/// Draws the sheet over `page`, which holds what's behind it; that gets dimmed.
pub fn render(fonts: Fonts, page: Page, title: []const u8, subtitle: []const u8, blocks: []const Block) !void {
    const h = try height(fonts, blocks);
    const sheet_top = style.screen_height - h;
    page.dim(0, 0, page.width, sheet_top);
    page.roundRect(0, sheet_top, page.width, h + corner, corner, style.black);
    page.roundRect(0, sheet_top + 2, page.width, h + corner, corner - 1, style.white);
    page.roundRect(page.width / 2 - 36, sheet_top + 18, 72, 8, 4, 0xb0); // Grab bar
    const avail: f32 = @floatFromInt(page.width - 2 * style.margin);
    try draw.clipped(fonts.hero, page, style.margin, @intCast(sheet_top + 100), title, avail);
    try draw.clipped(fonts.caption, page, style.margin, @intCast(sheet_top + 148), subtitle, avail);
    page.tint(style.margin, sheet_top + 120, @intFromFloat(avail), 44, style.faded);
    page.fillRect(style.margin, sheet_top + header - 18, page.width - 2 * style.margin, 1, style.rule);
    var w = Writer{ .fonts = fonts, .page = page, .y = @intCast(sheet_top + header + line_step - 10), .bottom = @intCast(style.screen_height - bottom_pad) };
    for (blocks) |b| try w.block(b);
}
