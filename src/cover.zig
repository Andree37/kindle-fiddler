//! Book thumbnails, decoded once and scaled to library size.
const std = @import("std");
const file = @import("file.zig");

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

/// Decodes a JPEG and draws it as large as fits, centred on black.
pub fn fillScreen(alloc: std.mem.Allocator, jpeg: []const u8, buf: []u8, width_px: usize, height_px: usize) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(jpeg.ptr, @intCast(jpeg.len), &w, &h) orelse return false;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return false;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const fit = fitted(sw, sh, width_px, height_px);
    const scaled = alloc.alloc(u8, fit.w * fit.h) catch return false;
    defer alloc.free(scaled);
    scale(pixels[0 .. sw * sh], sw, sh, scaled, fit.w, fit.h);
    @memset(buf, 0x00);
    const left = (width_px - fit.w) / 2;
    const top = (height_px - fit.h) / 2;
    for (0..fit.h) |row| {
        @memcpy(buf[(top + row) * width_px + left ..][0..fit.w], scaled[row * fit.w..][0..fit.w]);
    }
    return true;
}

const Size = struct { w: usize, h: usize };

/// Largest size with the source's shape that fits the target.
pub fn fitted(sw: usize, sh: usize, dw: usize, dh: usize) Size {
    if (sw * dh > sh * dw) return .{ .w = dw, .h = sh * dw / sw };
    return .{ .w = sw * dh / sh, .h = dh };
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

test "covers keep their shape on screen" {
    try std.testing.expectEqual(Size{ .w = 1272, .h = 1696 }, fitted(600, 800, 1272, 1696));
    try std.testing.expectEqual(Size{ .w = 1060, .h = 1696 }, fitted(500, 800, 1272, 1696));
    try std.testing.expectEqual(Size{ .w = 1272, .h = 636 }, fitted(800, 400, 1272, 1696));
}
