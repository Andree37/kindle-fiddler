//! The Aa sheet: reading settings, in four tabs.
const std = @import("std");
const library = @import("library.zig");
const menu = @import("menu.zig");
const slider = @import("slider.zig");
const text = @import("../book/text.zig");

const top = 228; // Under the toolbar
const tabs_height = 92;
pub const height = 760; // Where the sheet ends on screen
const margin = 72;
const screen_width = 1272;
const content_top = top + tabs_height + 16;

pub const Tab = enum { themes, font, layout, more };
const tab_labels = [_][]const u8{ "Themes", "Font", "Layout", "More" };

pub const Hit = union(enum) {
    none,
    tab: Tab,
    theme: usize,
    family: usize,
    bold,
    text_size,
    spacing,
    margins,
    alignment,
    clock,
    refresh,
};

pub const Row = struct { hit: Hit, label: []const u8, top: u32, steps: usize };
pub const size_row = Row{ .hit = .text_size, .label = "Text size", .top = content_top + 256, .steps = menu.sizes.len };
pub const spacing_row = Row{ .hit = .spacing, .label = "Line spacing", .top = content_top, .steps = menu.spacings.len };
pub const margin_row = Row{ .hit = .margins, .label = "Margins", .top = content_top + 146, .steps = menu.margins.len };
pub const row_height = 146;

const family_top = content_top;
const family_height = 88;
const family_width = (screen_width - 2 * margin) / 2;
const bold_top = content_top + 186;
const toggle_height = 76;
const align_top = content_top + 292;
const clock_top = content_top + 8;
const refresh_top = content_top + 108;

const theme_width = 340;
const theme_gap = 34;
const theme_top = content_top + 20;
const theme_height = 300;

pub const Theme = struct { label: []const u8, size: usize, spacing: usize, margin: usize };
pub const themes = [_]Theme{
    .{ .label = "Compact", .size = 1, .spacing = 0, .margin = 0 },
    .{ .label = "Standard", .size = 2, .spacing = 1, .margin = 1 },
    .{ .label = "Large", .size = 4, .spacing = 2, .margin = 2 },
};

fn rowSlider(r: Row) slider.Slider {
    return .{ .left = 110, .right = 1162, .y = r.top + 92 };
}

/// Step for a finger at `x` on a row's slider.
pub fn stepAt(r: Row, x: i32) usize {
    return slider.valueAt(rowSlider(r), x, @intCast(r.steps - 1));
}

fn within(y: i32, from: i32, size: i32) bool {
    return y >= from and y < from + size;
}

pub fn hit(tab: Tab, x: i32, y: i32) Hit {
    if (y < top + tabs_height) {
        const cell: i32 = screen_width / tab_labels.len;
        const at = @divTrunc(std.math.clamp(x, @as(i32, 0), screen_width - 1), cell);
        return .{ .tab = @enumFromInt(at) };
    }
    switch (tab) {
        .themes => {
            if (!within(y, theme_top, theme_height)) return .none;
            for (0..themes.len) |i| {
                const left: i32 = margin + @as(i32, @intCast(i)) * (theme_width + theme_gap);
                if (x >= left and x < left + theme_width) return .{ .theme = i };
            }
        },
        .font => {
            if (within(y, family_top, 2 * family_height)) {
                const row: usize = @intCast(@divTrunc(y - family_top, family_height));
                const col: usize = if (x < screen_width / 2) 0 else 1;
                return .{ .family = row * 2 + col };
            }
            if (within(y, bold_top, toggle_height)) return .bold;
            if (within(y, size_row.top, row_height)) return .text_size;
        },
        .layout => {
            if (within(y, spacing_row.top, row_height)) return .spacing;
            if (within(y, margin_row.top, row_height)) return .margins;
            if (within(y, align_top, toggle_height)) return .alignment;
        },
        .more => {
            if (within(y, clock_top, toggle_height)) return .clock;
            if (within(y, refresh_top, toggle_height)) return .refresh;
        },
    }
    return .none;
}

fn drawToggle(fonts: library.Fonts, page: text.Page, y: u32, label: []const u8, on: bool) !void {
    try fonts.small.draw(page, margin, @intCast(y + 50), label);
    const w: u32 = 100;
    const h: u32 = 48;
    const x: u32 = page.width - margin - w;
    const box = y + 14;
    page.fillRect(x, box, w, h, 0x00);
    if (!on) page.fillRect(x + 3, box + 3, w - 6, h - 6, 0xff);
    const knob_x: i32 = @intCast(if (on) x + w - h / 2 else x + h / 2);
    const knob_y: i32 = @intCast(box + h / 2);
    page.disc(knob_x, knob_y, 18, 0, 0xff);
    if (!on) page.disc(knob_x, knob_y, 15, 12, 0x00);
}

/// One slider row, redrawn alone while dragging.
pub fn drawRow(fonts: library.Fonts, page: text.Page, r: Row, value: usize, mono: bool) !void {
    page.fillRect(0, r.top, page.width, row_height, 0xff);
    try fonts.small.draw(page, margin, @intCast(r.top + 48), r.label);
    const bar = rowSlider(r);
    const max: u32 = @intCast(r.steps - 1);
    slider.drawTicks(page, bar, max);
    slider.draw(page, bar, slider.knobAt(bar, @intCast(value), max));
    if (mono) page.threshold(r.top, row_height);
}

fn drawTabs(fonts: library.Fonts, page: text.Page, tab: Tab) !void {
    const cell: u32 = page.width / tab_labels.len;
    for (tab_labels, 0..) |label, i| {
        const left: u32 = @as(u32, @intCast(i)) * cell;
        const active = i == @intFromEnum(tab);
        const font = if (active) fonts.title else fonts.small;
        const w = try font.measure(label);
        const x = @as(f32, @floatFromInt(left + cell / 2)) - w / 2;
        try font.draw(page, x, top + 60, label);
        if (active) {
            page.fillRect(@intFromFloat(x), top + 78, @intFromFloat(w), 5, 0x00);
        } else {
            page.tint(left + 8, top + 20, cell - 16, 54, 0x50);
        }
    }
    page.fillRect(0, top + tabs_height - 2, page.width, 1, 0xb0);
}

fn drawThemes(fonts: library.Fonts, page: text.Page, chosen: menu.Settings) !void {
    for (themes, 0..) |t, i| {
        const left: u32 = margin + @as(u32, @intCast(i)) * (theme_width + theme_gap);
        const active = chosen.size == t.size and chosen.spacing == t.spacing and chosen.margin == t.margin;
        const edge: u32 = if (active) 6 else 2;
        page.fillRect(left, theme_top, theme_width, theme_height, 0x00);
        page.fillRect(left + edge, theme_top + edge, theme_width - 2 * edge, theme_height - 2 * edge, 0xff);
        // Text lines drawn to scale, so the choice shows rather than tells.
        const gap: u32 = 16 + @as(u32, @intCast(t.spacing)) * 8;
        const inset: u32 = 28 + @as(u32, @intCast(t.margin)) * 16;
        const thick: u32 = 5 + @as(u32, @intCast(t.size));
        var y: u32 = theme_top + 44;
        while (y < theme_top + 204) : (y += gap + thick) {
            page.fillRect(left + inset, y, theme_width - 2 * inset, thick, 0x60);
        }
        const w = try fonts.small.measure(t.label);
        try fonts.small.draw(page, @as(f32, @floatFromInt(left + theme_width / 2)) - w / 2, theme_top + 264, t.label);
    }
}

fn drawFont(fonts: library.Fonts, page: text.Page, chosen: menu.Settings) !void {
    for (menu.families, 0..) |f, i| {
        const row: u32 = @intCast(i / 2);
        const left: u32 = margin + @as(u32, @intCast(i % 2)) * family_width;
        const y = family_top + row * family_height;
        const active = i == chosen.font;
        const font = if (active) fonts.title else fonts.small;
        try font.draw(page, @floatFromInt(left), @intCast(y + 56), f.label);
        if (active) page.fillRect(left, y + 70, @intFromFloat(try font.measure(f.label)), 5, 0x00);
    }
    try drawToggle(fonts, page, bold_top, "Bold", chosen.bold);
    try drawRow(fonts, page, size_row, chosen.size, false);
}

pub fn render(fonts: library.Fonts, page: text.Page, tab: Tab, chosen: menu.Settings) !void {
    page.fillRect(0, top, page.width, height - top, 0xff);
    page.fillRect(0, height - 4, page.width, 4, 0x00);
    try drawTabs(fonts, page, tab);
    switch (tab) {
        .themes => try drawThemes(fonts, page, chosen),
        .font => try drawFont(fonts, page, chosen),
        .layout => {
            try drawRow(fonts, page, spacing_row, chosen.spacing, false);
            try drawRow(fonts, page, margin_row, chosen.margin, false);
            try drawToggle(fonts, page, align_top, "Justify text", !chosen.left_align);
        },
        .more => {
            try drawToggle(fonts, page, clock_top, "Show clock while reading", chosen.clock);
            try drawToggle(fonts, page, refresh_top, "Page refresh every 20 pages", chosen.refresh);
        },
    }
}

test "tabs split the top row evenly" {
    try std.testing.expectEqual(Hit{ .tab = .themes }, hit(.font, 100, 260));
    try std.testing.expectEqual(Hit{ .tab = .more }, hit(.font, 1200, 260));
}

test "each tab maps its own controls" {
    try std.testing.expectEqual(Hit{ .theme = 1 }, hit(.themes, 620, 500));
    try std.testing.expectEqual(Hit{ .family = 0 }, hit(.font, 200, family_top + 20));
    try std.testing.expectEqual(Hit{ .family = 3 }, hit(.font, 900, family_top + family_height + 20));
    try std.testing.expectEqual(Hit.bold, hit(.font, 600, bold_top + 20));
    try std.testing.expectEqual(Hit.text_size, hit(.font, 600, size_row.top + 90));
    try std.testing.expectEqual(Hit.spacing, hit(.layout, 600, spacing_row.top + 90));
    try std.testing.expectEqual(Hit.margins, hit(.layout, 600, margin_row.top + 90));
    try std.testing.expectEqual(Hit.alignment, hit(.layout, 600, align_top + 20));
    try std.testing.expectEqual(Hit.clock, hit(.more, 600, clock_top + 20));
    try std.testing.expectEqual(Hit.refresh, hit(.more, 600, refresh_top + 20));
}

test "the sheet stays inside itself" {
    try std.testing.expect(size_row.top + row_height <= height);
    try std.testing.expect(align_top + toggle_height <= height);
    try std.testing.expect(theme_top + theme_height <= height);
}

test "controls of other tabs don't answer" {
    try std.testing.expectEqual(Hit.none, hit(.more, 600, 600));
}
