//! Book thumbnails, decoded once and scaled to library size.
const std = @import("std");
const file = @import("../platform/file.zig");
const text = @import("../book/text.zig");

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

/// The part of a `sw` x `sh` picture that fills a `dw` x `dh` screen when scaled:
/// the centre, with the overflowing sides (or top and bottom) cut off.
pub fn cropToFill(sw: usize, sh: usize, dw: usize, dh: usize) struct { x: usize, y: usize, w: usize, h: usize } {
    if (sw * dh > sh * dw) {
        const w = @max(1, sh * dw / dh);
        return .{ .x = (sw - w) / 2, .y = 0, .w = w, .h = sh };
    }
    const h = @max(1, sw * dh / dw);
    return .{ .x = 0, .y = (sh - h) / 2, .w = sw, .h = h };
}

/// Decodes a cover and fills the whole screen with it, cropping what overflows.
/// `stride` is bytes per row in `buf`, which can be more than the visible width.
pub fn fillScreen(alloc: std.mem.Allocator, jpeg: []const u8, buf: []u8, width_px: usize, height_px: usize, stride: usize) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(jpeg.ptr, @intCast(jpeg.len), &w, &h) orelse return false;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return false;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const crop = cropToFill(sw, sh, width_px, height_px);
    const part = alloc.alloc(u8, crop.w * crop.h) catch return false;
    defer alloc.free(part);
    for (0..crop.h) |row| @memcpy(part[row * crop.w ..][0..crop.w], pixels[(crop.y + row) * sw + crop.x ..][0..crop.w]);
    const scaled = alloc.alloc(u8, width_px * height_px) catch return false;
    defer alloc.free(scaled);
    scale(part, crop.w, crop.h, scaled, width_px, height_px);
    dither(alloc, scaled, width_px) catch return false;
    for (0..height_px) |row| @memcpy(buf[row * stride ..][0..width_px], scaled[row * width_px ..][0..width_px]);
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
pub fn blit(page: text.Page, ready: []const u8, x: u32, y: u32, w: u32, h: u32) void {
    if (x + w > page.width or y + h > page.height or ready.len < @as(usize, w) * h) return;
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
    try std.testing.expect(cropToFill(1, 10000, 1272, 1696).h >= 1);
    try std.testing.expect(cropToFill(10000, 1, 1272, 1696).w >= 1);
    var none: [0]u8 = .{};
    try dither(std.testing.allocator, &none, 0);
}

test "covers fill the screen, cropping the overflow evenly" {
    // A wide cover keeps its full height and loses equal strips at the sides.
    const wide = cropToFill(1000, 1000, 1272, 1696);
    try std.testing.expectEqual(@as(usize, 1000), wide.h);
    try std.testing.expectEqual(@as(usize, 750), wide.w);
    try std.testing.expectEqual(@as(usize, 125), wide.x);
    // A tall one keeps its full width and loses top and bottom.
    const tall = cropToFill(600, 1200, 1272, 1696);
    try std.testing.expectEqual(@as(usize, 600), tall.w);
    try std.testing.expectEqual(@as(usize, 800), tall.h);
    try std.testing.expectEqual(@as(usize, 200), tall.y);
}
