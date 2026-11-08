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
    try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, menu.height, app.page_waveform, .partial));
}

pub fn closeMenu(a: *app.App, background: []const u8) !void {
    @memcpy(a.screen.pixels, background);
    try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, menu.height, app.page_waveform, .partial));
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
    const screen_page = a.page(a.screen.pixels);
    var marker: ?u32 = null;
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |first| {
                // One update at a time: overlapping ones smear on the panel.
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const level = menu.levelAt(row, a.input.latestDrag() orelse first);
                if (level == rowValue(a, row)) continue;
                setRowValue(a, row, level);
                try menu.drawSlider(a.ui, screen_page, row, level, true);
                marker = try a.screen.updateRegion(0, menu.bandTop(row), a.screen.width, menu.band_height, .a2, .partial);
            },
            .drag_end => break,
            .tap, .hold, .pull, .tick, .unlock => {},
            .lock, .power, .idle, .stop => {
                a.input.stashed = action;
                break;
            },
        }
    }
    if (marker) |m| try a.screen.waitComplete(m);
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
    a.quick = system.read();
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
