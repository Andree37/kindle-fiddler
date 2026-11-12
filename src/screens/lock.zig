//! The lock screen: the book's cover while the Kindle sleeps.
const std = @import("std");
const catalog = @import("../model/catalog.zig");
const os = @import("../linux/os.zig");
const cover = @import("../gfx/image.zig");
const file = @import("../linux/file.zig");
const kfx = @import("../kindle/kfx.zig");
const nowUs = os.nowUs;
const app = @import("../app.zig");

pub const lock_redraw_us = 1500 * 1000;

pub const lock_redraws = 2;

/// Shows the book's cover while the Kindle sleeps, then puts the screen back.
pub fn lockScreen(a: *app.App, entry: ?*const catalog.Entry) !void {
    @memcpy(a.lock_saved, a.screen.pixels);
    const target = a.lock_cover;
    var drawn = false;
    if (entry) |e| {
        if (e.isLocal()) {
            if (file.map(e.path)) |data| {
                defer file.unmap(data);
                if (kfx.coverImage(data)) |jpeg| drawn = cover.fillScreen(a.alloc, jpeg, target, a.screen.width, a.screen.height, a.screen.stride);
            } else |_| {}
        }
        if (!drawn and e.thumbnail.len > 0) {
            if (file.map(e.thumbnail)) |data| {
                defer file.unmap(data);
                drawn = cover.fillScreen(a.alloc, data, target, a.screen.width, a.screen.height, a.screen.stride);
            } else |_| {}
        }
    }
    if (!drawn) {
        @memset(target, 0xff);
        if (entry) |e| try a.ui.hero.draw(a.page(target), 120, 800, e.title);
    }
    try a.present(target, .gc16, .full);
    std.debug.print("locked, cover drawn: {}\n", .{drawn});

    // Stock paints its own lock screen just after this, so draw over it again.
    const tick = a.input.tick_us;
    defer a.input.tick_us = tick;
    a.input.tick_us = lock_redraw_us;
    a.input.last_tick = nowUs();
    a.input.locked = true;
    defer a.input.locked = false;
    var redraws: u32 = 0;
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tick => {
                redraws += 1;
                // Only when stock painted over it, and only the pixels it changed.
                if (!std.mem.eql(u8, a.screen.pixels, target)) {
                    std.debug.print("lock cover repainted\n", .{});
                    try a.present(target, .gc16, .partial);
                }
                if (redraws == lock_redraws) a.input.tick_us = 0;
            },
            .unlock => break,
            .computer, .stop => {
                a.input.stashed = action;
                break;
            },
            else => {},
        }
    }
    a.input.last_input = nowUs();
    try a.present(a.lock_saved, .gc16, .full);
}
