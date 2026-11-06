//! Glyph cache and page layout for 8-bit grayscale pages.
const std = @import("std");
const Paragraph = @import("kfx.zig").Paragraph;

extern fn ft_open(ttf: [*]const u8) ?*anyopaque;
extern fn ft_scale(f: *anyopaque, px: f32) f32;
extern fn ft_vmetrics(f: *anyopaque, asc: *c_int, desc: *c_int, gap: *c_int) void;
extern fn ft_index(f: *anyopaque, cp: c_int) c_int;
extern fn ft_hmetrics(f: *anyopaque, g: c_int, adv: *c_int, lsb: *c_int) void;
extern fn ft_kern(f: *anyopaque, a: c_int, b: c_int) c_int;
extern fn ft_bitmap(f: *anyopaque, scale: f32, g: c_int, w: *c_int, h: *c_int, xo: *c_int, yo: *c_int) ?[*]u8;

fn isCombining(cp: u32) bool {
    return cp >= 0x300 and cp <= 0x36f;
}

const Glyph = struct {
    index: c_int,
    advance: f32,
    width: i32,
    height: i32,
    x_off: i32,
    y_off: i32,
    pixels: ?[*]u8,
};

pub const Font = struct {
    handle: *anyopaque,
    scale: f32,
    ascent: i32,
    line_height: i32,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, ttf: []const u8, px: f32, line_spacing: f32) !Font {
        const handle = ft_open(ttf.ptr) orelse return error.BadFont;
        const scale = ft_scale(handle, px);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        ft_vmetrics(handle, &asc, &desc, &gap);
        return .{
            .handle = handle,
            .scale = scale,
            .ascent = @intFromFloat(@as(f32, @floatFromInt(asc)) * scale),
            .line_height = @intFromFloat(px * line_spacing),
            .alloc = alloc,
        };
    }

    fn glyph(f: *Font, cp: u32) !Glyph {
        if (f.glyphs.get(cp)) |g| return g;
        const index = ft_index(f.handle, @intCast(cp));
        var adv: c_int = 0;
        var lsb: c_int = 0;
        ft_hmetrics(f.handle, index, &adv, &lsb);
        var w: c_int = 0;
        var h: c_int = 0;
        var xo: c_int = 0;
        var yo: c_int = 0;
        const px = ft_bitmap(f.handle, f.scale, index, &w, &h, &xo, &yo);
        const g = Glyph{
            .index = index,
            .advance = @as(f32, @floatFromInt(adv)) * f.scale,
            .width = w,
            .height = h,
            .x_off = xo,
            .y_off = yo,
            .pixels = px,
        };
        try f.glyphs.put(f.alloc, cp, g);
        return g;
    }

    fn kern(f: *Font, a: Glyph, b: Glyph) f32 {
        return @as(f32, @floatFromInt(ft_kern(f.handle, a.index, b.index))) * f.scale;
    }

    pub fn measure(f: *Font, word: []const u8) !f32 {
        var width: f32 = 0;
        var prev: ?Glyph = null;
        var it = (std.unicode.Utf8View.init(word) catch return 0).iterator();
        while (it.nextCodepoint()) |cp| {
            if (isCombining(cp)) continue;
            const g = try f.glyph(cp);
            if (prev) |p| width += f.kern(p, g);
            width += g.advance;
            prev = g;
        }
        return width;
    }

    /// Bytes of `word` that fit in `avail`, always at least one character.
    pub fn fit(f: *Font, word: []const u8, avail: f32) !usize {
        var width: f32 = 0;
        var prev: ?Glyph = null;
        var last: usize = 0;
        var it = (std.unicode.Utf8View.init(word) catch return word.len).iterator();
        while (it.nextCodepoint()) |cp| {
            if (isCombining(cp)) {
                last = it.i;
                continue;
            }
            const g = try f.glyph(cp);
            if (prev) |p| width += f.kern(p, g);
            width += g.advance;
            if (width > avail and last > 0) return last;
            last = it.i;
            prev = g;
        }
        return last;
    }

    pub fn draw(f: *Font, page: Page, x_start: f32, baseline: i32, word: []const u8) !void {
        var x = x_start;
        var prev: ?Glyph = null;
        var it = (std.unicode.Utf8View.init(word) catch return).iterator();
        var base_x = x;
        while (it.nextCodepoint()) |cp| {
            const g = try f.glyph(cp);
            if (isCombining(cp)) {
                // Centred over the letter it belongs to.
                const letter = if (prev) |p| p.advance else 0;
                const mark = @as(f32, @floatFromInt(g.width));
                page.blit(g, @as(i32, @intFromFloat(base_x + (letter - mark) / 2)), baseline + g.y_off);
                continue;
            }
            if (prev) |p| x += f.kern(p, g);
            page.blit(g, @as(i32, @intFromFloat(x)) + g.x_off, baseline + g.y_off);
            base_x = x;
            x += g.advance;
            prev = g;
        }
    }
};

pub const Page = struct {
    buf: []u8,
    width: u32,
    height: u32,
    stride: u32,

    pub fn fillRect(p: Page, x: u32, y: u32, w: u32, h: u32, value: u8) void {
        var row = y;
        while (row < @min(y + h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            @memset(p.buf[start .. start + @min(w, p.width - x)], value);
        }
    }

    /// Fades an area toward white, for disabled controls.
    pub fn dim(p: Page, x: u32, y: u32, w: u32, h: u32) void {
        var row = y;
        while (row < @min(y + h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            for (p.buf[start .. start + @min(w, p.width - x)]) |*px| px.* = 0xc8 + px.* / 5;
        }
    }

    fn darken(p: Page, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0 or x >= p.width or y >= p.height or coverage <= 0) return;
        const at = @as(usize, @intCast(y)) * p.stride + @as(usize, @intCast(x));
        const value: u8 = @intFromFloat(255 * (1 - std.math.clamp(coverage, 0, 1)));
        p.buf[at] = @min(p.buf[at], value);
    }

    /// Smooth line with round ends.
    pub fn stroke(p: Page, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {
        const r = width / 2;
        const left: i32 = @intFromFloat(@floor(@min(x0, x1) - r - 1));
        const right: i32 = @intFromFloat(@ceil(@max(x0, x1) + r + 1));
        const top: i32 = @intFromFloat(@floor(@min(y0, y1) - r - 1));
        const bottom: i32 = @intFromFloat(@ceil(@max(y0, y1) + r + 1));
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = @max(dx * dx + dy * dy, 0.0001);
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const t = std.math.clamp(((px - x0) * dx + (py - y0) * dy) / len2, 0, 1);
                const ex = px - (x0 + t * dx);
                const ey = py - (y0 + t * dy);
                p.darken(x, y, r + 0.5 - @sqrt(ex * ex + ey * ey));
            }
        }
    }

    pub fn arc(p: Page, cx: f32, cy: f32, radius: f32, from: f32, to: f32, width: f32) void {
        const steps = 48;
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const a0 = from + (to - from) * @as(f32, @floatFromInt(i)) / steps;
            const a1 = from + (to - from) * @as(f32, @floatFromInt(i + 1)) / steps;
            p.stroke(cx + @cos(a0) * radius, cy + @sin(a0) * radius, cx + @cos(a1) * radius, cy + @sin(a1) * radius, width);
        }
    }

    /// Fills a polygon, sampling each pixel four times for smooth edges.
    pub fn fillPoly(p: Page, points: []const [2]f32) void {
        var min_x: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (points) |pt| {
            min_x = @min(min_x, pt[0]);
            max_x = @max(max_x, pt[0]);
            min_y = @min(min_y, pt[1]);
            max_y = @max(max_y, pt[1]);
        }
        var y: i32 = @intFromFloat(@floor(min_y));
        while (y <= @as(i32, @intFromFloat(@ceil(max_y)))) : (y += 1) {
            var x: i32 = @intFromFloat(@floor(min_x));
            while (x <= @as(i32, @intFromFloat(@ceil(max_x)))) : (x += 1) {
                var hits: u32 = 0;
                for ([_][2]f32{ .{ 0.25, 0.25 }, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, .{ 0.75, 0.75 } }) |s| {
                    const sx = @as(f32, @floatFromInt(x)) + s[0];
                    const sy = @as(f32, @floatFromInt(y)) + s[1];
                    var inside = false;
                    var j = points.len - 1;
                    for (points, 0..) |a, i| {
                        const b = points[j];
                        if ((a[1] > sy) != (b[1] > sy) and sx < (b[0] - a[0]) * (sy - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
                        j = i;
                    }
                    if (inside) hits += 1;
                }
                p.darken(x, y, @as(f32, @floatFromInt(hits)) / 4);
            }
        }
    }

    /// White tick for the finished badge.
    pub fn fillPolyWhiteCheck(p: Page, cx: f32, cy: f32) void {
        const pts = [_][4]f32{ .{ -11, 1, -3, 9 }, .{ -3, 9, 12, -8 } };
        for (pts) |l| {
            var t: f32 = 0;
            while (t <= 1) : (t += 0.02) {
                const x = cx + l[0] + (l[2] - l[0]) * t;
                const y = cy + l[1] + (l[3] - l[1]) * t;
                p.disc(@intFromFloat(x), @intFromFloat(y), 2, 0, 0xff);
            }
        }
    }

    /// Lifts black toward `floor`, for secondary text and lines.
    pub fn tint(p: Page, x: u32, y: u32, w: u32, h: u32, floor: u8) void {
        var row = y;
        while (row < @min(y + h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            for (p.buf[start .. start + @min(w, p.width - x)]) |*px| {
                const span: u32 = 255 - @as(u32, floor);
                px.* = @intCast(@as(u32, floor) + @as(u32, px.*) * span / 255);
            }
        }
    }

    /// Forces a band to pure black and white, for waveforms that can't show gray.
    pub fn threshold(p: Page, top: u32, height: u32) void {
        const start = top * p.stride;
        for (p.buf[start .. start + height * p.stride]) |*px| px.* = if (px.* < 128) 0x00 else 0xff;
    }

    /// Filled disc, or a ring when `inner` is above zero.
    pub fn disc(p: Page, cx: i32, cy: i32, outer: i32, inner: i32, value: u8) void {
        var y = -outer;
        while (y <= outer) : (y += 1) {
            var x = -outer;
            while (x <= outer) : (x += 1) {
                const d = x * x + y * y;
                if (d > outer * outer or d < inner * inner) continue;
                const px = cx + x;
                const py = cy + y;
                if (px < 0 or py < 0 or px >= p.width or py >= p.height) continue;
                p.buf[@as(usize, @intCast(py)) * p.stride + @as(usize, @intCast(px))] = value;
            }
        }
    }

    pub fn copyImage(p: Page, x: u32, y: u32, src: []const u8, w: u32, h: u32) void {
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            @memcpy(p.buf[(y + row) * p.stride + x ..][0..w], src[row * w..][0..w]);
        }
    }

    fn blit(p: Page, g: Glyph, x: i32, y: i32) void {
        const src = g.pixels orelse return;
        var row: i32 = 0;
        while (row < g.height) : (row += 1) {
            const py = y + row;
            if (py < 0 or py >= @as(i32, @intCast(p.height))) continue;
            var col: i32 = 0;
            while (col < g.width) : (col += 1) {
                const px = x + col;
                if (px < 0 or px >= @as(i32, @intCast(p.width))) continue;
                const a = src[@intCast(row * g.width + col)];
                const at = @as(usize, @intCast(py)) * p.stride + @as(usize, @intCast(px));
                p.buf[at] = @min(p.buf[at], 255 - a);
            }
        }
    }
};

/// Where a note reference landed on a page.
pub const Hit = struct { x: i32, y: i32, w: i32, h: i32, target: u32 };

pub const Hits = struct {
    items: [32]Hit = undefined,
    len: usize = 0,

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

pub const Layout = struct {
    margin_x: i32,
    margin_top: i32,
    margin_bottom: i32,
    indent: f32,
    reference: ?*Font = null, // Smaller font for note references
};

const max_words = 96;

const Link = @import("kfx.zig").Link;

fn findReference(links: []const Link, paras: []const Paragraph, start: usize, len: usize) ?Link {
    for (links) |link| {
        if (link.end <= start or link.start >= start + len) continue;
        if (link.target < paras.len and paras[link.target].note_start) return link;
    }
    return null;
}

/// Lay out one page and return where the next page starts.
/// With `page` null this only measures, which is how the book gets paginated.
pub fn layoutPage(font: *Font, maybe_page: ?Page, geometry: Page, paras: []const Paragraph, start: Pos, l: Layout, hits: ?*Hits) !Pos {
    if (maybe_page) |p| @memset(p.buf, 0xff);
    const page = geometry;
    const line_width: f32 = @floatFromInt(@as(i32, @intCast(page.width)) - 2 * l.margin_x);
    const space = try font.measure(" ");
    const bottom = @as(i32, @intCast(page.height)) - l.margin_bottom;
    var y = l.margin_top + font.ascent;
    var pos = start;

    while (pos.para < paras.len) : ({
        pos.para += 1;
        pos.byte = 0;
    }) {
        if (paras[pos.para].note) continue;
        const text = paras[pos.para].text;
        const links = paras[pos.para].links;
        var i = pos.byte;
        var indent: f32 = if (i == 0) l.indent else 0;

        while (i < text.len) {
            while (i < text.len and (text[i] == ' ' or text[i] == '\n')) i += 1;
            if (i >= text.len) break;

            var words: [max_words][]const u8 = undefined;
            var widths: [max_words]f32 = undefined;
            var n: usize = 0;
            var used: f32 = 0;
            var j = i;
            var line_ends_para = false;
            const avail = line_width - indent;

            while (n < max_words) {
                var end = j;
                while (end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
                const word = text[j..end];
                const w = try font.measure(word);
                if (n == 0 and w > avail) {
                    // Wider than a whole line, as with a URL or unspaced CJK: split it.
                    const part = word[0..try font.fit(word, avail)];
                    words[0] = part;
                    widths[0] = try font.measure(part);
                    n = 1;
                    j += part.len;
                    break;
                }
                const gap: f32 = if (n == 0) 0 else space;
                if (n > 0 and used + gap + w > avail) break;
                words[n] = word;
                widths[n] = w;
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

            if (y > bottom) return .{ .para = pos.para, .byte = i };

            var word_total: f32 = 0;
            for (widths[0..n]) |w| word_total += w;
            var gap = space;
            if (!line_ends_para and n > 1) {
                gap = @min((avail - word_total) / @as(f32, @floatFromInt(n - 1)), space * 2.5);
            }
            var x = @as(f32, @floatFromInt(l.margin_x)) + indent;
            for (words[0..n], widths[0..n]) |word, w| {
                var shrink: f32 = 0; // A small mark takes less room than was measured
                if (maybe_page) |p| {
                    const word_start = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
                    const reference = findReference(links, paras, word_start, word.len);
                    if (reference) |r| {
                        // Raised and small, like a printed note mark.
                        const small = l.reference orelse font;
                        const a = @max(r.start, word_start) - word_start;
                        const b = @min(r.end, word_start + word.len) - word_start;
                        try font.draw(p, x, y, word[0..a]);
                        const mark_x = x + try font.measure(word[0..a]);
                        try small.draw(p, mark_x, y - @divTrunc(font.line_height, 3), word[a..b]);
                        const mark_w = try small.measure(word[a..b]);
                        try font.draw(p, mark_x + mark_w, y, word[b..]);
                        shrink = try font.measure(word[a..b]) - mark_w;
                        if (hits) |h| h.add(.{
                            .x = @intFromFloat(mark_x),
                            .y = y - font.ascent,
                            .w = @intFromFloat(@max(mark_w, 1)),
                            .h = font.line_height,
                            .target = r.target,
                        });
                    } else {
                        try font.draw(p, x, y, word);
                    }
                }
                x += w + gap - shrink;
            }
            y += font.line_height;
            i = j;
            indent = if (line_ends_para) l.indent else 0;
        }
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
