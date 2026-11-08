//! Book thumbnails, decoded once and scaled to library size.
const std = @import("std");
const check = @import("../base/check.zig");
const file = @import("../linux/file.zig");
const Page = @import("page.zig").Page;

extern fn img_gray(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn img_free(p: [*]u8) void;

pub const width = 252;
pub const height = 333;
pub const hero_width = 270;
pub const hero_height = 357;

/// Box filter: each output pixel averages the source pixels it covers.
pub fn scale(src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    for (0..dh) |y| {
        const y0 = y * sh / dh;
        const y1 = @max((y + 1) * sh / dh, y0 + 1);
        for (0..dw) |x| {
            const x0 = x * sw / dw;
            const x1 = @max((x + 1) * sw / dw, x0 + 1);
            var sum: u32 = 0;
            for (y0..y1) |sy| {
                for (x0..x1) |sx| sum += src[sy * sw + sx];
            }
            dst[y * dw + x] = @intCast(sum / @as(u32, @intCast((y1 - y0) * (x1 - x0))));
        }
    }
}

/// Rounds to the 16 grays the panel shows, spreading each pixel's rounding error
/// onto its neighbours (Floyd-Steinberg). Without it the panel rounds by itself,
/// and dark areas flatten into one murky gray.
pub fn dither(alloc: std.mem.Allocator, pixels: []u8, w: usize) !void {
    if (w == 0) return;
    const errs = try alloc.alloc(i16, 2 * (w + 2));
    defer alloc.free(errs);
    @memset(errs, 0);
    var cur = errs[0 .. w + 2];
    var nxt = errs[w + 2 ..];
    const h = pixels.len / w;
    for (0..h) |y| {
        for (0..w) |x| {
            const i = y * w + x;
            const want = std.math.clamp(@as(i16, pixels[i]) + @divTrunc(cur[x + 1], 16), 0, 255);
            const got = @divTrunc(want + 8, 17) * 17;
            pixels[i] = @intCast(got);
            const e = want - got;
            cur[x + 2] += e * 7;
            nxt[x] += e * 3;
            nxt[x + 1] += e * 5;
            nxt[x + 2] += e;
        }
        std.mem.swap([]i16, &cur, &nxt);
        @memset(nxt, 0);
    }
}

/// The largest size with a picture's shape that fits inside a `dw` x `dh` box.
pub fn fitted(sw: usize, sh: usize, dw: usize, dh: usize) struct { w: usize, h: usize } {
    if (sw * dh > sh * dw) return .{ .w = dw, .h = @max(1, sh * dw / sw) };
    return .{ .w = @max(1, sw * dh / sh), .h = dh };
}

/// Decodes a cover and shows all of it, as large as fits, centred on black.
/// `stride` is bytes per row in `buf`, which can be more than the visible width.
pub fn fillScreen(alloc: std.mem.Allocator, jpeg: []const u8, buf: []u8, width_px: usize, height_px: usize, stride: usize) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(jpeg.ptr, @intCast(jpeg.len), &w, &h) orelse return false;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return false;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const fit = fitted(sw, sh, width_px, height_px);
    const ready = prepare(alloc, pixels[0 .. sw * sh], sw, sh, fit.w, fit.h) orelse return false;
    defer alloc.free(ready);
    for (0..height_px) |row| @memset(buf[row * stride ..][0..width_px], 0x00);
    const left = (width_px - fit.w) / 2;
    const top = (height_px - fit.h) / 2;
    for (0..fit.h) |row| @memcpy(buf[(top + row) * stride + left ..][0..fit.w], ready[row * fit.w ..][0..fit.w]);
    return true;
}

/// Scales decoded grayscale pixels to `w` x `h` and dithers them for the panel,
/// ready to copy onto pages. The caller owns the result.
pub fn prepare(alloc: std.mem.Allocator, pixels: []const u8, sw: usize, sh: usize, w: usize, h: usize) ?[]u8 {
    if (w == 0 or h == 0 or sw == 0 or sh == 0 or pixels.len < sw * sh) return null;
    const out = alloc.alloc(u8, w * h) catch return null;
    scale(pixels[0 .. sw * sh], sw, sh, out, w, h);
    dither(alloc, out, w) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

/// Decodes a JPEG or PNG, then prepares it at `w` x `h`.
pub fn decodeAndPrepare(alloc: std.mem.Allocator, encoded: []const u8, w: usize, h: usize) ?[]u8 {
    var sw: c_int = 0;
    var sh: c_int = 0;
    const pixels = img_gray(encoded.ptr, @intCast(encoded.len), &sw, &sh) orelse return null;
    defer img_free(pixels);
    if (sw <= 0 or sh <= 0) return null;
    return prepare(alloc, pixels[0..@intCast(sw * sh)], @intCast(sw), @intCast(sh), w, h);
}

/// Copies a prepared picture into a box on a page.
pub fn blit(page: Page, ready: []const u8, x: u32, y: u32, w: u32, h: u32) void {
    check.thatf(ready.len == @as(usize, w) * h, "picture of {d} bytes fills a {d}x{d} box", .{ ready.len, w, h });
    if (x + w > page.width or y + h > page.height) return;
    for (0..h) |row| @memcpy(page.buf[(y + row) * page.stride + x ..][0..w], ready[row * w ..][0..w]);
}

/// Returns a grayscale cover at the given size, or null if it can't be read.
pub fn load(alloc: std.mem.Allocator, path: [*:0]const u8, dw: usize, dh: usize) ?[]u8 {
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(data.ptr, @intCast(data.len), &w, &h) orelse return null;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return null;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const out = alloc.alloc(u8, dw * dh) catch return null;
    scale(pixels[0 .. sw * sh], sw, sh, out, dw, dh);
    return out;
}

test "scaling down averages" {
    const src = [_]u8{ 0, 100, 200, 100 };
    var dst: [1]u8 = undefined;
    scale(&src, 2, 2, &dst, 1, 1);
    try std.testing.expectEqual(@as(u8, 100), dst[0]);
}

test "scaling up repeats" {
    const src = [_]u8{ 10, 20 };
    var dst: [4]u8 = undefined;
    scale(&src, 2, 1, &dst, 4, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 20, 20 }, &dst);
}

test "dithering keeps only panel grays and the overall tone" {
    var pixels: [64 * 64]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast((i % 64) * 4);
    var before: u32 = 0;
    for (pixels) |p| before += p;
    try dither(std.testing.allocator, &pixels, 64);
    var after: u32 = 0;
    for (pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p % 17);
        after += p;
    }
    const diff = @as(i64, before) - @as(i64, after);
    try std.testing.expect(@abs(diff) < 64 * 64 * 2);
}

test "a sliver of an image still crops to something, and dithering nothing is safe" {
    try std.testing.expect(fitted(1, 10000, 1272, 1696).w >= 1);
    try std.testing.expect(fitted(10000, 1, 1272, 1696).h >= 1);
    var none: [0]u8 = .{};
    try dither(std.testing.allocator, &none, 0);
}

test "covers keep their shape on screen" {
    const screen_w = 1272;
    const screen_h = 1696;
    try std.testing.expectEqual(@as(usize, 1272), fitted(600, 800, screen_w, screen_h).w);
    const narrow = fitted(500, 800, screen_w, screen_h);
    try std.testing.expectEqual(@as(usize, 1060), narrow.w);
    try std.testing.expectEqual(@as(usize, 1696), narrow.h);
    try std.testing.expectEqual(@as(usize, 636), fitted(800, 400, screen_w, screen_h).h);
}
