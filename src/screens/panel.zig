//! The quick panel: light, warmth, airplane mode, Bluetooth and sync, over a book or the library.
const std = @import("std");
const library = @import("../ui/library.zig");
const menu = @import("../ui/menu.zig");
const lipc = @import("../kindle/lipc.zig");
const quick_model = @import("../model/quick.zig");
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
        lipc.setWarmth(level, a.quick.schedule);
    } else {
        a.quick.brightness = level;
        lipc.setBrightness(level);
    }
}

/// Shows a slider row at rest. One non-flashing pass that also clears what the fast
/// waveform left behind while dragging.
fn showRow(a: *app.App, row: menu.Row, level: u32) !void {
    try menu.drawSlider(a.ui, a.page(a.screen.pixels), row, level, false);
    try a.screen.waitComplete(try a.screen.updateRegion(0, menu.bandTop(row), a.screen.width, menu.band_height, .reagl, .full));
}

/// Follows a finger along a panel slider from where it landed until it lifts.
/// The knob slides under the finger; the light changes a step at a time, after each
/// frame is on its way, so the lipc call never holds the knob back.
pub fn dragRow(a: *app.App, row: menu.Row, first_x: i32) !void {
    a.input.beginDrag();
    const Follow = struct {
        a: *app.App,
        row: menu.Row,
        knob: *u32,
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            const knob = menu.knobUnder(x);
            if (knob == f.knob.*) return null;
            const level = menu.levelAt(f.row, x);
            try menu.drawSliderAt(f.a.ui, f.a.page(f.a.screen.pixels), f.row, level, knob, true);
            const span = menu.knobSpan(f.knob.*, knob);
            f.knob.* = knob;
            const marker = try f.a.screen.updateRegion(span.left, menu.bandTop(f.row), span.width, menu.band_height, .a2, .partial);
            if (level != rowValue(f.a, f.row)) setRowValue(f.a, f.row, level);
            return marker;
        }
    };
    var knob = menu.knobAt(row, rowValue(a, row));
    const follow = Follow{ .a = a, .row = row, .knob = &knob };
    const first = try follow.moved(first_x, 0);
    try app.followDrag(a, first, follow);
    try showRow(a, row, rowValue(a, row));
}

/// Runs a panel control. False means the tap wasn't on one. Each control redraws only
/// its own part of the panel, before telling the Kindle, so the tap answers at once.
pub fn panelControl(a: *app.App, background: []const u8, choice: menu.Hit, x: i32) !bool {
    switch (choice) {
        .slider => try dragRow(a, menu.brightness_row, x),
        .warmth => try dragRow(a, menu.warmth_row, x),
        .dimmer, .brighter, .cooler, .warmer => {
            const row = if (choice == .dimmer or choice == .brighter) menu.brightness_row else menu.warmth_row;
            const level = quick_model.stepBrightness(rowValue(a, row), choice == .brighter or choice == .warmer);
            try showRow(a, row, level);
            setRowValue(a, row, level);
        },
        .airplane, .bluetooth, .sync => {
            switch (choice) {
                .airplane => a.quick.airplane = !a.quick.airplane,
                .bluetooth => a.quick.bluetooth = !a.quick.bluetooth,
                else => a.quick.syncing = true,
            }
            const box = menu.shortcutBox(choice).?;
            try menu.drawShortcut(a.ui, a.page(a.screen.pixels), choice, &a.quick);
            const marker = try a.screen.updateRegion(box.left, box.top, box.width, box.height, app.page_waveform, .partial);
            switch (choice) {
                .airplane => lipc.setAirplane(a.quick.airplane),
                .bluetooth => lipc.setBluetooth(a.quick.bluetooth),
                else => lipc.syncNow(),
            }
            try a.screen.waitComplete(marker);
        },
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            try drawMenu(a, background);
            lipc.setSchedule(a.quick.schedule);
        },
        else => return false,
    }
    return true;
}

/// The quick panel over the library. Returns true to quit to the stock UI.
pub fn libraryMenu(a: *app.App, background: []const u8) !bool {
    a.quick = lipc.read(a.quick);
    try drawMenu(a, background);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| {
                const choice = menu.hit(t.x, t.y);
                if (try panelControl(a, background, choice, t.x)) continue;
                switch (choice) {
                    .settings => {
                        lipc.openSettings();
                        return true;
                    },
                    .kindle => return true, // noface.sh brings back the Kindle's home
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
            .power, .computer, .stop => return true,
        }
    }
}
