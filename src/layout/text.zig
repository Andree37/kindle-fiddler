//! Glyph cache and page layout for 8-bit grayscale pages.
const std = @import("std");
const Font = @import("../gfx/font.zig").Font;
const Page = @import("../gfx/page.zig").Page;
const book_model = @import("../model/book.zig");
const Paragraph = @import("../model/book.zig").Paragraph;

/// Where a note reference landed on a page.
pub const Hit = struct { x: i32, y: i32, w: i32, h: i32, target: u32 };

/// A word on a page and where it came from, for selection.
pub const Word = struct { x: i32, y: i32, w: i32, h: i32, para: u32, start: u32, end: u32 };

/// Part of a paragraph with a highlight on it.
pub const Mark = struct { para: u32, start: u32, end: u32 };

const mark_shade = 0xe4; // Very faint, so highlighted text reads like any other

fn isMarked(marks: []const Mark, para: usize, start: usize, end: usize) bool {
    for (marks) |m| {
        if (m.para == para and start < m.end and end > m.start) return true;
    }
    return false;
}

pub const Hits = struct {
    items: [32]Hit = undefined,
    len: usize = 0,
    words: [1024]Word = undefined,
    word_count: usize = 0,

    pub fn clear(h: *Hits) void {
        h.len = 0;
        h.word_count = 0;
    }

    fn addWord(h: *Hits, word: Word) void {
        if (h.word_count == h.words.len) return;
        h.words[h.word_count] = word;
        h.word_count += 1;
    }

    fn add(h: *Hits, hit: Hit) void {
        if (h.len == h.items.len) return;
        h.items[h.len] = hit;
        h.len += 1;
    }

    /// Finds the reference at a tap, with room for how small they are.
    pub fn find(h: *const Hits, x: i32, y: i32) ?u32 {
        const pad = 30;
        for (h.items[0..h.len]) |r| {
            if (x >= r.x - pad and x < r.x + r.w + pad and y >= r.y - pad and y < r.y + r.h + pad) return r.target;
        }
        return null;
    }
};

test "tap near a reference finds it" {
    var hits = Hits{};
    hits.add(.{ .x = 100, .y = 200, .w = 20, .h = 40, .target = 7 });
    try std.testing.expectEqual(@as(u32, 7), hits.find(90, 190).?);
    try std.testing.expect(hits.find(300, 200) == null);
}

pub const Pos = struct { para: usize = 0, byte: usize = 0 };

/// Where layout gets the font for a weight, slant and size. Without one, every
/// word uses the base font.
pub const Faces = struct {
    ctx: *anyopaque,
    pick: *const fn (ctx: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*Font,
};

/// Draws a picture into a page. Decoding lives outside layout, which only needs sizes.
pub const Images = struct {
    ctx: *anyopaque,
    draw: *const fn (ctx: *anyopaque, page: Page, image: book_model.Image, x: u32, y: u32, w: u32, h: u32) void,
};

pub const Layout = struct {
    faces: ?Faces = null,
    images: ?Images = null,
    margin_x: i32,
    margin_top: i32,
    margin_bottom: i32,
    indent: f32,
    reference: ?*Font = null, // Smaller font for note references
    marks: []const Mark = &.{},
    justify: bool = true,
};

const max_words = 96;

const Link = book_model.Link;

fn findReference(links: []const Link, paras: []const Paragraph, start: usize, len: usize) ?Link {
    for (links) |link| {
        if (link.end <= start or link.start >= start + len) continue;
        if (link.target < paras.len and paras[link.target].note_start) return link;
    }
    return null;
}

fn face(l: Layout, base: *Font, bold: bool, italic: bool, size: u8) !*Font {
    const f = l.faces orelse return base;
    return f.pick(f.ctx, bold, italic, size);
}

/// Bold and italic for a word: its paragraph's, plus any run it starts in.
fn wordFace(l: Layout, base: *Font, p: Paragraph, word_start: usize) !*Font {
    var bold = p.look.bold;
    var italic = p.look.italic;
    for (p.runs) |r| {
        if (word_start >= r.start and word_start < r.end) {
            bold = bold or r.bold;
            italic = italic or r.italic;
        }
    }
    return face(l, base, bold, italic, p.look.size);
}

/// A picture's size on the page: as large as fits, but at most twice its own size,
/// so small ornaments don't turn into blocks.
pub fn imageSize(img: book_model.Image, max_w: f32, max_h: f32) struct { w: i32, h: i32 } {
    const w: f32 = @floatFromInt(img.width);
    const h: f32 = @floatFromInt(img.height);
    const scale = @min(@min(max_w / w, max_h / h), 2.0);
    return .{ .w = @max(1, @as(i32, @intFromFloat(w * scale))), .h = @max(1, @as(i32, @intFromFloat(h * scale))) };
}

fn spaceLines(tenths: u8, base: *Font) i32 {
    return @divTrunc(@as(i32, tenths) * base.line_height, 10);
}

/// Lay out one page and return where the next page starts.
/// With `page` null this only measures, which is how the book gets paginated.
pub fn layoutPage(font: *Font, maybe_page: ?Page, geometry: Page, paras: []const Paragraph, start: Pos, l: Layout, hits: ?*Hits) !Pos {
    if (maybe_page) |p| @memset(p.buf, 0xff);
    const page = geometry;
    const line_width: f32 = @floatFromInt(@as(i32, @intCast(page.width)) - 2 * l.margin_x);
    const bottom = @as(i32, @intCast(page.height)) - l.margin_bottom;
    var top = l.margin_top; // Top of the next line
    var pos = start;

    while (pos.para < paras.len) : ({
        pos.para += 1;
        pos.byte = 0;
    }) {
        const para = paras[pos.para];
        if (para.note) continue;
        if (para.image) |img| {
            const room: f32 = @floatFromInt(bottom - l.margin_top);
            const size = imageSize(img, line_width, room);
            // A picture never splits: it starts the next page unless it opens this one.
            if (top + size.h > bottom + font.ascent and top > l.margin_top) return .{ .para = pos.para, .byte = 0 };
            if (maybe_page) |p| {
                if (l.images) |im| {
                    const x: u32 = @intCast(l.margin_x + @divTrunc(@as(i32, @intFromFloat(line_width)) - size.w, 2));
                    im.draw(im.ctx, p, img, x, @intCast(top), @intCast(size.w), @intCast(size.h));
                }
            }
            top += size.h + @divTrunc(font.line_height, 2);
            continue;
        }
        const text = para.text;
        const links = para.links;
        const look = para.look;
        const pf = try face(l, font, look.bold, look.italic, look.size); // Sets the line height
        const space = try pf.measure(" ");
        // Headings and centred lines aren't indented, and only body text is justified.
        const plain = look.size == book_model.normal_size and (look.alignment == .auto or look.alignment == .justify or look.alignment == .left);
        const justify = switch (look.alignment) {
            .auto => l.justify and look.size == book_model.normal_size,
            .justify => true,
            else => false,
        };
        var i = pos.byte;
        var indent: f32 = if (i == 0 and plain) l.indent else 0;
        if (i == 0 and top > l.margin_top) top += spaceLines(look.space_before, font);

        while (i < text.len) {
            while (i < text.len and (text[i] == ' ' or text[i] == '\n')) i += 1;
            if (i >= text.len) break;

            var words: [max_words][]const u8 = undefined;
            var widths: [max_words]f32 = undefined;
            var fonts: [max_words]*Font = undefined;
            var n: usize = 0;
            var used: f32 = 0;
            var j = i;
            var line_ends_para = false;
            const avail = line_width - indent;

            while (n < max_words) {
                var end = j;
                while (end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
                const word = text[j..end];
                const wf = try wordFace(l, font, para, j);
                const w = try wf.measure(word);
                if (n == 0 and w > avail) {
                    // Wider than a whole line, as with a URL or unspaced CJK: split it.
                    const part = word[0..try wf.fit(word, avail)];
                    words[0] = part;
                    widths[0] = try wf.measure(part);
                    fonts[0] = wf;
                    n = 1;
                    j += part.len;
                    break;
                }
                const gap: f32 = if (n == 0) 0 else space;
                if (n > 0 and used + gap + w > avail) break;
                words[n] = word;
                widths[n] = w;
                fonts[n] = wf;
                n += 1;
                used += gap + w;
                j = end;
                if (j >= text.len or text[j] == '\n') {
                    line_ends_para = true;
                    if (j < text.len) j += 1;
                    break;
                }
                while (j < text.len and text[j] == ' ') j += 1;
                if (j >= text.len) {
                    line_ends_para = true;
                    break;
                }
            }

            const y = top + pf.ascent; // Baseline
            if (y > bottom) return .{ .para = pos.para, .byte = i };

            var word_total: f32 = 0;
            for (widths[0..n]) |w| word_total += w;
            var gap = space;
            if (justify and !line_ends_para and n > 1) {
                gap = @min((avail - word_total) / @as(f32, @floatFromInt(n - 1)), space * 2.5);
            }
            const line_used = word_total + gap * @as(f32, @floatFromInt(@max(n, 1) - 1));
            var x = @as(f32, @floatFromInt(l.margin_x)) + indent + switch (look.alignment) {
                .center => @max(avail - line_used, 0) / 2,
                .right => @max(avail - line_used, 0),
                else => 0,
            };
            for (words[0..n], widths[0..n], fonts[0..n]) |word, w, wf| {
                var shrink: f32 = 0; // A small mark takes less room than was measured
                if (maybe_page) |p| {
                    const word_start = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
                    if (isMarked(l.marks, pos.para, word_start, word_start + word.len)) {
                        // Reaches into the gap, so a marked phrase reads as one band.
                        const band: u32 = @intFromFloat(w + gap);
                        p.fillRect(@intFromFloat(x), @intCast(y - pf.ascent + 4), band, @intCast(pf.line_height - 8), mark_shade);
                    }
                    if (hits) |h| h.addWord(.{
                        .x = @intFromFloat(x),
                        .y = y - pf.ascent,
                        .w = @intFromFloat(w),
                        .h = pf.line_height,
                        .para = @intCast(pos.para),
                        .start = @intCast(word_start),
                        .end = @intCast(word_start + word.len),
                    });
                    const reference = findReference(links, paras, word_start, word.len);
                    if (reference) |r| {
                        // Raised and small, like a printed note mark.
                        const small = l.reference orelse wf;
                        const a = @max(r.start, word_start) - word_start;
                        const b = @min(r.end, word_start + word.len) - word_start;
                        try wf.draw(p, x, y, word[0..a]);
                        const mark_x = x + try wf.measure(word[0..a]);
                        try small.draw(p, mark_x, y - @divTrunc(pf.line_height, 3), word[a..b]);
                        const mark_w = try small.measure(word[a..b]);
                        try wf.draw(p, mark_x + mark_w, y, word[b..]);
                        shrink = try wf.measure(word[a..b]) - mark_w;
                        if (hits) |h| h.add(.{
                            .x = @intFromFloat(mark_x),
                            .y = y - pf.ascent,
                            .w = @intFromFloat(@max(mark_w, 1)),
                            .h = pf.line_height,
                            .target = r.target,
                        });
                    } else {
                        try wf.draw(p, x, y, word);
                    }
                }
                x += w + gap - shrink;
            }
            top += pf.line_height;
            i = j;
            indent = if (line_ends_para and plain) l.indent else 0;
        }
        top += spaceLines(look.space_after, font);
    }
    return pos;
}

pub fn renderPage(font: *Font, page: Page, paras: []const Paragraph, start: Pos, l: Layout, hits: ?*Hits) !Pos {
    return layoutPage(font, page, page, paras, start, l, hits);
}

/// Hard black and white, for waveforms that cannot show gray.
pub fn threshold(src: []const u8, dst: []u8) void {
    for (src, dst) |s, *d| d.* = if (s < 128) 0x00 else 0xff;
}

test "pictures fit the page and small ones stay small" {
    const big = imageSize(.{ .data = "", .width = 2000, .height = 1000 }, 1000, 1400);
    try std.testing.expectEqual(@as(i32, 1000), big.w);
    try std.testing.expectEqual(@as(i32, 500), big.h);
    const tall = imageSize(.{ .data = "", .width = 500, .height = 3000 }, 1000, 1400);
    try std.testing.expectEqual(@as(i32, 1400), tall.h);
    const ornament = imageSize(.{ .data = "", .width = 50, .height = 16 }, 1000, 1400);
    try std.testing.expectEqual(@as(i32, 100), ornament.w);
}
