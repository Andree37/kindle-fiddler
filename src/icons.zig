//! Panel icons, drawn as smooth vector shapes.
const std = @import("std");
const text = @import("text.zig");

const Pen = struct {
    page: text.Page,
    cx: f32,
    cy: f32,
    scale: f32 = 1,

    fn x(p: Pen, v: f32) f32 {
        return p.cx + v * p.scale;
    }

    fn y(p: Pen, v: f32) f32 {
        return p.cy + v * p.scale;
    }

    fn line(p: Pen, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {
        p.page.stroke(p.x(x0), p.y(y0), p.x(x1), p.y(y1), width * p.scale);
    }

    fn arc(p: Pen, ox: f32, oy: f32, radius: f32, from: f32, to: f32, width: f32) void {
        p.page.arc(p.x(ox), p.y(oy), radius * p.scale, std.math.degreesToRadians(from), std.math.degreesToRadians(to), width * p.scale);
    }
};

const pi: f32 = std.math.pi;

pub fn ring(page: text.Page, cx: f32, cy: f32, radius: f32) void {
    page.arc(cx, cy, radius, 0, 2 * pi, 3);
}

pub fn airplane(page: text.Page, cx: f32, cy: f32) void {
    const outline = [_][2]f32{
        .{ 0, -36 },  .{ 4, -31 },  .{ 5, -11 },  .{ 33, 7 },   .{ 33, 14 },  .{ 5, 4 },
        .{ 4, 21 },   .{ 13, 29 },  .{ 13, 34 },  .{ 0, 29 },   .{ -13, 34 }, .{ -13, 29 },
        .{ -4, 21 },  .{ -5, 4 },   .{ -33, 14 }, .{ -33, 7 },  .{ -5, -11 }, .{ -4, -31 },
    };
    var points: [outline.len][2]f32 = undefined;
    const c = @cos(pi / 4);
    for (outline, &points) |o, *r| {
        r.* = .{ cx + (o[0] - o[1]) * c, cy + (o[0] + o[1]) * c };
    }
    page.fillPoly(&points);
}

pub fn bluetooth(page: text.Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.line(0, -32, 0, 32, 4);
    p.line(0, -32, 17, -16, 4);
    p.line(17, -16, -17, 16, 4);
    p.line(-17, -16, 17, 16, 4);
    p.line(17, 16, 0, 32, 4);
}

pub fn wifi(page: text.Page, cx: f32, cy: f32, scale: f32, bars: u32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy, .scale = scale };
    page.disc(@intFromFloat(p.x(0)), @intFromFloat(p.y(24)), @intFromFloat(@max(6 * scale, 2)), 0, 0x00);
    const radii = [_]f32{ 19, 34, 49 };
    for (radii, 0..) |r, i| {
        if (bars > 0 and i >= bars) continue;
        p.arc(0, 24, r, -135, -45, 6);
    }
}

pub fn sync(page: text.Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.arc(0, 0, 28, 200, 330, 4);
    p.arc(0, 0, 28, 20, 150, 4);
    arrowHead(p, 28, 330);
    arrowHead(p, 28, 150);
}

/// Barbs at the end of a clockwise arc, pointing along it.
fn arrowHead(p: Pen, radius: f32, degrees: f32) void {
    const a = std.math.degreesToRadians(degrees);
    const tip_x = @cos(a) * radius;
    const tip_y = @sin(a) * radius;
    const back = a - pi / 2;
    for ([_]f32{ -0.6, 0.6 }) |spread| {
        const b = back + spread;
        p.line(tip_x, tip_y, tip_x + @cos(b) * 14, tip_y + @sin(b) * 14, 4);
    }
}

pub fn gear(page: text.Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.arc(0, 0, 25, 0, 360, 5);
    p.arc(0, 0, 11, 0, 360, 4);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * pi / 4;
        p.line(@cos(a) * 26, @sin(a) * 26, @cos(a) * 36, @sin(a) * 36, 9);
    }
}

/// Width of the charge bar. Kept in u32: @min with a literal narrows the type.
pub fn batteryFill(inner: u32, percent: u32) u32 {
    const level: u32 = @min(percent, 100);
    return inner * level / 100;
}

pub fn battery(page: text.Page, x: f32, y: f32, percent: u32) void {
    const w = 78;
    const h = 36;
    page.stroke(x, y, x + w, y, 3);
    page.stroke(x, y + h, x + w, y + h, 3);
    page.stroke(x, y, x, y + h, 3);
    page.stroke(x + w, y, x + w, y + h, 3);
    page.stroke(x + w + 7, y + 11, x + w + 7, y + h - 11, 6);
    const fill = batteryFill(w - 10, percent);
    if (fill > 0) page.fillRect(@intFromFloat(x + 5), @intFromFloat(y + 5), fill, h - 10, 0x00);
}

pub fn chevron(page: text.Page, cx: f32, cy: f32) void {
    page.stroke(cx - 42, cy + 13, cx, cy - 7, 4);
    page.stroke(cx, cy - 7, cx + 42, cy + 13, 4);
}

test "battery bar fills with charge" {
    try std.testing.expectEqual(@as(u32, 68), batteryFill(68, 100));
    try std.testing.expectEqual(@as(u32, 34), batteryFill(68, 50));
    try std.testing.expectEqual(@as(u32, 0), batteryFill(68, 0));
    try std.testing.expectEqual(@as(u32, 68), batteryFill(68, 250));
}
