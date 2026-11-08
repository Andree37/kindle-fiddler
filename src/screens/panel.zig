//! The quick panel: light, warmth, airplane mode and sync, over a book or the library.
const std = @import("std");
const library = @import("../ui/library.zig");
const menu = @import("../ui/menu.zig");
const system = @import("../platform/system.zig");
const app = @import("../app.zig");

/// Draws the quick panel over `background` and shows it.
pub fn drawMenu(a: *app.App, background: []const u8) !void {
    @memcpy(a.overlay, background);
    try menu.render(a.ui, a.page(a.overlay), &a.quick);
    @memcpy(a.screen.pixels, a.overlay);
    try a.showBand(0, menu.height);
}

pub fn closeMenu(a: *app.App, background: []const u8) !void {
    @memcpy(a.screen.pixels, background);
    try a.showBand(0, menu.height);
}

pub fn rowValue(a: *app.App, row: menu.Row) u32 {
    return if (row.y == menu.warmth_row.y) a.quick.warmth else a.quick.brightness;
}

pub fn setRowValue(a: *app.App, row: menu.Row, level: u32) void {
    if (row.y == menu.warmth_row.y) {
        a.quick.warmth = level;
        system.setWarmth(level, a.quick.schedule);
    } else {
        a.quick.brightness = level;
        system.setBrightness(level);
    }
}

/// Follows a finger along a panel slider until it lifts.
pub fn dragRow(a: *app.App, background: []const u8, row: menu.Row) !void {
    a.input.beginDrag();
    const Follow = struct {
        a: *app.App,
        row: menu.Row,
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            const level = menu.levelAt(f.row, x);
            if (level == rowValue(f.a, f.row)) return null;
            setRowValue(f.a, f.row, level);
            try menu.drawSlider(f.a.ui, f.a.page(f.a.screen.pixels), f.row, level, true);
            return try f.a.screen.updateRegion(0, menu.bandTop(f.row), f.a.screen.width, menu.band_height, .a2, .partial);
        }
    };
    try app.followDrag(a, null, Follow{ .a = a, .row = row });
    try drawMenu(a, background);
    try app.cleanBand(a, menu.bandTop(row), menu.band_height);
}

/// Runs a panel control. False means the tap wasn't on one.
pub fn panelControl(a: *app.App, background: []const u8, choice: menu.Hit, x: i32) !bool {
    if (!applyQuick(a, choice, x)) return false;
    switch (choice) {
        .slider => try dragRow(a, background, menu.brightness_row),
        .warmth => try dragRow(a, background, menu.warmth_row),
        else => try drawMenu(a, background),
    }
    return true;
}

/// Applies a light, warmth or airplane change. False means the tap wasn't one of those.
pub fn applyQuick(a: *app.App, change: menu.Hit, x: i32) bool {
    switch (change) {
        .dimmer, .brighter => {
            a.quick.brightness = system.stepBrightness(a.quick.brightness, change == .brighter);
            system.setBrightness(a.quick.brightness);
        },
        .slider => setRowValue(a, menu.brightness_row, menu.levelAt(menu.brightness_row, x)),
        .cooler, .warmer => setRowValue(a, menu.warmth_row, system.stepBrightness(a.quick.warmth, change == .warmer)),
        .warmth => setRowValue(a, menu.warmth_row, menu.levelAt(menu.warmth_row, x)),
        .sync => {
            a.quick.syncing = true;
            system.syncNow();
        },
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            system.setSchedule(a.quick.schedule);
        },
        .airplane => {
            a.quick.airplane = !a.quick.airplane;
            system.setAirplane(a.quick.airplane);
        },
        else => return false,
    }
    return true;
}

/// The quick panel over the library. Returns true to quit to the stock UI.
pub fn libraryMenu(a: *app.App, background: []const u8) !bool {
    a.quick = system.read(a.quick);
    try drawMenu(a, background);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| {
                const choice = menu.hit(t.x, t.y);
                if (try panelControl(a, background, choice, t.x)) continue;
                switch (choice) {
                    .settings => {
                        system.openSettings();
                        return true;
                    },
                    .close => {
                        try closeMenu(a, background);
                        return false;
                    },
                    else => {},
                }
            },
            .pull, .hold, .drag, .drag_end, .tick, .unlock => {},
            .lock => {
                a.input.stashed = .lock;
                try closeMenu(a, background);
                return false;
            },
            .power, .idle, .stop => return true,
        }
    }
}
