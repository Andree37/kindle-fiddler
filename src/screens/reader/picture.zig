//! A book's picture on the whole screen, from pressing and holding it on the page.
//! Tap to zoom in (up to four times as close), centred where the tap lands;
//! double-tap to see the whole picture again; drag to move around a zoomed picture;
//! the round button closes it.
const std = @import("std");
const book_model = @import("../../model/book.zig");
const memory = @import("../../base/memory.zig");
const image = @import("../../gfx/image.zig");
const jpegxr = @import("../../kindle/jpegxr.zig");
const icons = @import("../../ui/icons.zig");
const draw = @import("../../ui/draw.zig");
const style = @import("../../ui/style.zig");
const hwtcon = @import("../../kindle/hwtcon.zig");
const app = @import("../../app.zig");
const os = @import("../../linux/os.zig");

/// Bigger than this and it isn't worth the memory: a page-sized scan is ~5M.
const max_pixels = 24 * 1000 * 1000;
/// Zoom steps after fitting the screen: twice, then four times as close.
const steps = [_]f32{ 1, 2, 4 };
/// The close button, top right, a fingertip across.
const close_r = 50;
const close_cx = style.screen_width - 40 - close_r;
const close_cy = 40 + close_r;
/// A finger that moves less than this between touching and lifting has tapped.
const tap_slop = 24;

fn decode(alloc: std.mem.Allocator, img: book_model.Image) ?image.Gray {
    if (@as(usize, img.width) * img.height > max_pixels) return null;
    if (jpegxr.isJpegXr(img.data)) {
        const g = jpegxr.decodeJpegXr(alloc, img.data, img.width, img.height) orelse return null;
        return .{ .pixels = g.pixels, .width = g.width, .height = g.height };
    }
    const g = image.decodeGray(alloc, img.data) orelse return null;
    if (g.width * g.height > max_pixels) return null;
    return g;
}

const View = struct {
    picture: image.Gray,
    step: usize = 0,
    cx: f32,
    cy: f32,
    fit: f32, // Screen pixels per picture pixel when it just fits

    fn zoom(v: View) f32 {
        return v.fit * steps[v.step];
    }

    fn clamp(v: *View) void {
        const w: f32 = @floatFromInt(v.picture.width);
        const h: f32 = @floatFromInt(v.picture.height);
        v.cx = image.clampCentre(v.cx, w, style.screen_width, v.zoom());
        v.cy = image.clampCentre(v.cy, h, style.screen_height, v.zoom());
    }

    /// The picture point under a screen point.
    fn pictureAt(v: View, x: i32, y: i32) struct { x: f32, y: f32 } {
        return .{
            .x = v.cx + (@as(f32, @floatFromInt(x)) - style.screen_width / 2) / v.zoom(),
            .y = v.cy + (@as(f32, @floatFromInt(y)) - style.screen_height / 2) / v.zoom(),
        };
    }
};

fn render(a: *app.App, v: View, settled: bool) !void {
    // Drawn in ordinary memory, then copied: the screen's own memory is slow to read
    // back, and dithering reads every pixel it writes
    const page = a.page(a.overlay);
    const t0 = os.nowUs();
    image.zoomed(v.picture, v.cx, v.cy, v.zoom(), page, a.screen.width, a.screen.height, settled);
    // Settled, it gets its 16 grays; while a finger moves, the fast black-and-white
    // update shows it anyway, so the dithering would be wasted
    if (settled) image.dither(a.alloc, a.overlay[0 .. a.screen.stride * a.screen.height], a.screen.stride) catch {};
    // The close button: a white disc with a ring and a cross
    page.disc(close_cx, close_cy, close_r, 0, style.black);
    page.disc(close_cx, close_cy, close_r - style.border, 0, style.white);
    const arm: f32 = 16;
    const cx: f32 = close_cx;
    const cy: f32 = close_cy;
    page.stroke(cx - arm, cy - arm, cx + arm, cy + arm, 4);
    page.stroke(cx - arm, cy + arm, cx + arm, cy - arm, 4);
    if (v.step == 0 and settled) {
        // How it works, at the bottom, until the first zoom
        const hint = "Tap to zoom in  \u{b7}  double-tap to zoom out  \u{b7}  drag to move";
        const w: u32 = @intFromFloat(try a.ui.caption.measure(hint) + 64);
        const left = (a.screen.width - w) / 2;
        const top = a.screen.height - 120;
        page.roundRect(left, top, w, 64, 32, style.black);
        page.roundRect(left + 2, top + 2, w - 4, 60, 30, style.white);
        try draw.centered(a.ui.caption, page, @floatFromInt(a.screen.width / 2), @intCast(top + 42), hint);
    }
    @memcpy(a.screen.pixels, a.overlay);
    std.debug.print("picture drawn in {d} ms\n", .{(os.nowUs() - t0) / 1000});
    try a.screen.waitComplete(try a.screen.update(if (settled) .gc16 else .du, .partial));
}

/// How long after a tap a second one makes it a double tap.
const double_tap_us = 300 * 1000;

/// Waits briefly for a second tap, and lets it lift. True if one came.
fn tappedAgain(a: *app.App) bool {
    const tick = a.input.tick_us;
    defer a.input.tick_us = tick;
    a.input.tick_us = double_tap_us;
    a.input.last_tick = os.nowUs();
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tick => return false,
            .tap => {
                // Its lift isn't a new tap: follow it to the end
                a.input.beginDrag();
                while (true) {
                    const other = a.input.next();
                    switch (other) {
                        .drag_end => return true,
                        .lock, .power, .computer, .stop => {
                            a.input.stashed = other;
                            return true;
                        },
                        else => {},
                    }
                }
            },
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                return false;
            },
            else => {},
        }
    }
}

fn onClose(x: i32, y: i32) bool {
    const dx = x - close_cx;
    const dy = y - close_cy;
    const reach = close_r + 30;
    return dx * dx + dy * dy <= reach * reach;
}

/// Shows the picture until it's closed, then puts the page back as it was.
pub fn show(a: *app.App, img: book_model.Image) !void {
    var budget = memory.Budget{ .name = "picture", .child = std.heap.smp_allocator, .limit = 64 << 20 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer {
        arena.deinit();
        budget.report();
    }
    const picture = decode(arena.allocator(), img) orelse {
        try app.showNotice(a, "This picture can't be shown larger.");
        return;
    };
    std.debug.print("picture: {d}x{d}\n", .{ picture.width, picture.height });
    const saved = try arena.allocator().dupe(u8, a.screen.pixels);
    const pw: f32 = @floatFromInt(picture.width);
    const ph: f32 = @floatFromInt(picture.height);
    var v = View{ .picture = picture, .cx = pw / 2, .cy = ph / 2, .fit = @min(style.screen_width / pw, style.screen_height / ph) };
    try render(a, v, true);

    const deferred = a.input.deferred;
    const edges = a.input.edge_zones;
    const grips = a.input.grips;
    a.input.deferred = false; // Touches come at once, so a drag can follow them
    a.input.edge_zones = false;
    a.input.grips = false;
    defer {
        a.input.deferred = deferred;
        a.input.edge_zones = edges;
        a.input.grips = grips;
    }
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tap => |t| {
                if (onClose(t.x, t.y)) break;
                // Follow the finger: a drag pans, a still finger is a tap
                a.input.beginDrag();
                const start_cx = v.cx;
                const start_cy = v.cy;
                var moved = false;
                var last_x = t.x;
                var last_y = t.y;
                while (true) {
                    const next = a.input.next();
                    switch (next) {
                        .drag => |x| {
                            const latest = a.input.latestDrag() orelse x;
                            last_x = latest;
                            last_y = a.input.drag_y;
                            if (!moved and @abs(last_x - t.x) + @abs(last_y - t.y) < tap_slop) continue;
                            moved = true;
                            if (v.step == 0) continue; // The whole picture shows: nowhere to go
                            v.cx = start_cx - @as(f32, @floatFromInt(last_x - t.x)) / v.zoom();
                            v.cy = start_cy - @as(f32, @floatFromInt(last_y - t.y)) / v.zoom();
                            v.clamp();
                            try render(a, v, false);
                        },
                        .drag_end => break,
                        .lock, .power, .computer, .stop => {
                            a.input.stashed = next;
                            break;
                        },
                        else => {},
                    }
                }
                if (a.input.stashed != null) break;
                if (moved) {
                    if (v.step > 0) try render(a, v, true); // Its grays back
                    continue;
                }
                // A second tap soon after: back to the whole picture. Else one step
                // closer, centred on the tap, up to the closest step
                if (tappedAgain(a)) {
                    if (v.step == 0) continue;
                    v.step = 0;
                    v.cx = pw / 2;
                    v.cy = ph / 2;
                } else {
                    if (v.step + 1 == steps.len) continue;
                    const at = v.pictureAt(t.x, t.y);
                    v.step += 1;
                    v.cx = at.x;
                    v.cy = at.y;
                }
                v.clamp();
                std.debug.print("picture zoom {d}x\n", .{@as(u32, @intFromFloat(steps[v.step]))});
                try render(a, v, true);
            },
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                break;
            },
            else => {},
        }
    }
    @memcpy(a.screen.pixels, saved);
    try a.screen.waitComplete(try a.screen.update(.gc16, .full));
}

test "taps on and near the close button close" {
    try std.testing.expect(onClose(close_cx, close_cy));
    try std.testing.expect(onClose(close_cx - close_r - 20, close_cy));
    try std.testing.expect(!onClose(600, 800));
}
