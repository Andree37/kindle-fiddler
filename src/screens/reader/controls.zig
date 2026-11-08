//! The reading toolbar and its Aa sheet.
const std = @import("std");
const aa = @import("../../ui/aa.zig");
const menu = @import("../../ui/menu.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// Draws the toolbar over the current page.
pub fn drawToolbar(a: *app.App, s: *sess.Session, title: []const u8, sheet: bool, whole_page: bool) !void {
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    try toolbar.render(a.ui, a.page(a.overlay), title, s.current, s.pages.len, &a.quick, if (sheet) a.tab else null, a.settings);
    @memcpy(a.screen.pixels, a.overlay);
    if (whole_page) {
        try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, a.screen.height, app.page_waveform, .partial));
        return;
    }
    const top: u32 = if (sheet) aa.height else toolbar.top_height;
    const first = try a.screen.updateRegion(0, 0, a.screen.width, top, app.page_waveform, .partial);
    try a.screen.waitComplete(try a.screen.updateRegion(0, toolbar.bottom_top, a.screen.width, a.screen.height - toolbar.bottom_top, app.page_waveform, .partial));
    try a.screen.waitComplete(first);
}

pub fn closeToolbar(a: *app.App, s: *sess.Session, sheet: bool) !void {
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    const top: u32 = if (sheet) aa.height else toolbar.top_height;
    const first = try a.screen.updateRegion(0, 0, a.screen.width, top, app.page_waveform, .partial);
    try a.screen.waitComplete(try a.screen.updateRegion(0, toolbar.bottom_top, a.screen.width, a.screen.height - toolbar.bottom_top, app.page_waveform, .partial));
    try a.screen.waitComplete(first);
}

/// Follows a finger along the page scrubber, then jumps there.
pub fn dragScrub(a: *app.App, s: *sess.Session, title: []const u8, sheet: bool, first_x: i32) !void {
    a.input.beginDrag();
    const screen_page = a.page(a.screen.pixels);
    var target = toolbar.pageAt(first_x, s.pages.len);
    var marker: ?u32 = null;
    const band = a.screen.height - toolbar.scrub_top;
    try toolbar.drawScrub(a.ui, screen_page, target, s.pages.len, true);
    marker = try a.screen.updateRegion(0, toolbar.scrub_top, a.screen.width, band, .a2, .partial);
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |first| {
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const next = toolbar.pageAt(a.input.latestDrag() orelse first, s.pages.len);
                if (next == target) continue;
                target = next;
                try toolbar.drawScrub(a.ui, screen_page, target, s.pages.len, true);
                marker = try a.screen.updateRegion(0, toolbar.scrub_top, a.screen.width, band, .a2, .partial);
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
    s.setPage(target);
    try drawToolbar(a, s, title, sheet, true);
    try app.cleanBand(a, toolbar.scrub_top, band);
}

pub fn rowSetting(a: *app.App, row: aa.Row) *usize {
    return switch (row.hit) {
        .text_size => &a.settings.size,
        .spacing => &a.settings.spacing,
        else => &a.settings.margin,
    };
}

/// Follows a finger along an Aa slider, and applies it when lifted.
pub fn dragSetting(a: *app.App, alloc: std.mem.Allocator, s: *sess.Session, title: []const u8, row: aa.Row, first_x: i32) !void {
    var value = aa.stepAt(row, first_x);
    const started = rowSetting(a, row).*;
    a.input.beginDrag();
    const screen_page = a.page(a.screen.pixels);
    try aa.drawRow(a.ui, screen_page, row, value, true);
    var marker: ?u32 = try a.screen.updateRegion(0, row.top, a.screen.width, aa.row_height, .a2, .partial);
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |first| {
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const next = aa.stepAt(row, a.input.latestDrag() orelse first);
                if (next == value) continue;
                value = next;
                try aa.drawRow(a.ui, screen_page, row, value, true);
                marker = try a.screen.updateRegion(0, row.top, a.screen.width, aa.row_height, .a2, .partial);
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
    if (value != started) {
        rowSetting(a, row).* = value;
        try sess.relayout(a, alloc, s);
    }
    try drawToolbar(a, s, title, true, true);
    try app.cleanBand(a, row.top, aa.row_height);
}

/// Handles a tap inside the Aa sheet.
pub fn tapSheet(a: *app.App, alloc: std.mem.Allocator, s: *sess.Session, title: []const u8, x: i32, y: i32) !void {
    switch (aa.hit(a.tab, x, y)) {
        .none => return,
        .tab => |tab| {
            a.tab = tab;
            return drawToolbar(a, s, title, true, false);
        },
        .text_size => return dragSetting(a, alloc, s, title, aa.size_row, x),
        .spacing => return dragSetting(a, alloc, s, title, aa.spacing_row, x),
        .margins => return dragSetting(a, alloc, s, title, aa.margin_row, x),
        .theme => |i| {
            const t = aa.themes[i];
            a.settings.size = t.size;
            a.settings.spacing = t.spacing;
            a.settings.margin = t.margin;
        },
        .family => |i| a.settings.font = i,
        .bold => a.settings.bold = !a.settings.bold,
        .alignment => a.settings.left_align = !a.settings.left_align,
        .clock => {
            a.settings.clock = !a.settings.clock;
            menu.save(a.settings_path, a.settings);
            return drawToolbar(a, s, title, true, false);
        },
        .refresh => {
            a.settings.refresh = !a.settings.refresh;
            menu.save(a.settings_path, a.settings);
            return drawToolbar(a, s, title, true, false);
        },
    }
    try sess.relayout(a, alloc, s);
    try drawToolbar(a, s, title, true, true);
}
