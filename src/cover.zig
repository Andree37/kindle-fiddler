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
