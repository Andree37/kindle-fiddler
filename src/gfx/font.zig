//! TrueType fonts through stb_truetype: measuring and drawing text onto a page.
const std = @import("std");
const Page = @import("page.zig").Page;

comptime {
    _ = @import("c_memory.zig"); // stb's malloc and free, which the C shim calls
}

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
                blit(page, g, @as(i32, @intFromFloat(base_x + (letter - mark) / 2)), baseline + g.y_off);
                continue;
            }
            if (prev) |p| x += f.kern(p, g);
            blit(page, g, @as(i32, @intFromFloat(x)) + g.x_off, baseline + g.y_off);
            base_x = x;
            x += g.advance;
            prev = g;
        }
    }
};

/// Draws a glyph's coverage onto a page, darkening what's already there.
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
