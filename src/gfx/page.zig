//! A grayscale pixel buffer and the shapes drawn onto it.
const std = @import("std");

pub const Page = struct {
    buf: []u8,
    width: u32,
    height: u32,
    stride: u32,

    /// Flips everything inside a circle, for controls that fill when on.
    pub fn invertDisc(p: Page, cx: i32, cy: i32, radius: i32) void {
        var y = -radius;
        while (y <= radius) : (y += 1) {
            var x = -radius;
            while (x <= radius) : (x += 1) {
                if (x * x + y * y > radius * radius) continue;
                const px = cx + x;
                const py = cy + y;
                if (px < 0 or py < 0 or px >= p.width or py >= p.height) continue;
                const at = @as(usize, @intCast(py)) * p.stride + @as(usize, @intCast(px));
                p.buf[at] = ~p.buf[at];
            }
        }
    }

    pub fn invert(p: Page, x: u32, y: u32, w: u32, h: u32) void {
        var row = y;
        while (row < @min(y + h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            for (p.buf[start .. start + @min(w, p.width - x)]) |*px| px.* = ~px.*;
        }
    }

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
};
