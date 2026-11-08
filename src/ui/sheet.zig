//! Actions for one book, opened from the three dots beside its cover.
const std = @import("std");
const draw = @import("draw.zig");
const style = @import("style.zig");
const catalog = @import("../book/catalog.zig");
const Fonts = @import("fonts.zig").Fonts;
const cover = @import("cover.zig");
const library = @import("library.zig");
const text = @import("../book/text.zig");

pub const Option = enum { download, remove, mark_read, mark_unread, confirm_remove, cancel };

const left = 136;
const width = 1000;
const header = 196;
const row = 112;
const screen_height = style.screen_height;

/// What a book offers. `confirming` swaps the list for the removal question.
pub fn options(e: *const catalog.Entry, confirming: bool, out: *[3]Option) []Option {
    if (confirming) {
        out[0] = .confirm_remove;
        out[1] = .cancel;
        return out[0..2];
    }
    var n: usize = 0;
    switch (e.availability) {
        .cloud => {
            out[0] = .download;
            n = 1;
        },
        .downloading => {},
        .local => {
            out[0] = .remove;
            n = 1;
        },
    }
    if (e.availability != .downloading) {
        out[n] = if (e.isRead()) .mark_unread else .mark_read;
        n += 1;
    }
    out[n] = .cancel;
    return out[0 .. n + 1];
}

fn label(o: Option) []const u8 {
    return switch (o) {
        .download => "Download",
        .remove => "Remove download",
        .mark_read => "Mark as read",
        .mark_unread => "Mark as unread",
        .confirm_remove => "Remove from this Kindle",
        .cancel => "Cancel",
    };
}

pub fn height(rows: usize) u32 {
    return header + @as(u32, @intCast(rows)) * row;
}

pub fn top(rows: usize) u32 {
    return (screen_height - height(rows)) / 2;
}

pub fn region() struct { x: u32, w: u32 } {
    return .{ .x = left, .w = width };
}

/// Which option a tap lands on, or null when it falls outside the card.
pub fn hit(x: i32, y: i32, rows: usize) ?usize {
    const card_top: i32 = @intCast(top(rows));
    if (x < left or x >= left + width or y < card_top) return null;
    const first = card_top + header;
    if (y >= first + @as(i32, @intCast(rows)) * row) return null;
    if (y < first) return rows; // On the card, not on an option
    return @intCast(@divTrunc(y - first, row));
}

pub fn render(fonts: Fonts, page: text.Page, e: *const catalog.Entry, list: []const Option, confirming: bool) !void {
    const card_top = top(list.len);
    const h = height(list.len);
    page.fillRect(left - 6, card_top - 6, width + 12, h + 12, 0xff);
    draw.box(page, left, card_top, width, h);

    const x: f32 = left + 48;
    const avail: f32 = width - 96;
    try library.drawClipped(fonts.title, page, x, @intCast(card_top + 76), e.title, avail);
    const line = if (confirming) "It stays in your Amazon library." else e.author;
    try library.drawClipped(fonts.caption, page, x, @intCast(card_top + 128), line, avail);
    page.tint(left + 48, card_top + 100, width - 96, 44, 0x50);

    for (list, 0..) |o, i| {
        const y = card_top + header + @as(u32, @intCast(i)) * row;
        page.fillRect(left + 3, y, width - 6, 1, 0xb0);
        const font = if (o == .cancel) fonts.small else fonts.title;
        try font.draw(page, x, @intCast(y + 70), label(o));
    }
}

fn entry(a: catalog.Availability, percent: u32) catalog.Entry {
    return .{ .path = "/a", .title = "T", .author = "", .percent = percent, .last = 0, .availability = a };
}

test "options follow where the book is" {
    var out: [3]Option = undefined;
    const local = entry(.local, 0);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_read, .cancel }, options(&local, false, &out));
    const cloud = entry(.cloud, 0);
    try std.testing.expectEqualSlices(Option, &.{ .download, .mark_read, .cancel }, options(&cloud, false, &out));
    const read = entry(.local, 100);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_unread, .cancel }, options(&read, false, &out));
    const busy = entry(.downloading, 0);
    try std.testing.expectEqualSlices(Option, &.{.cancel}, options(&busy, false, &out));
}

test "removal asks first" {
    var out: [3]Option = undefined;
    const local = entry(.local, 0);
    try std.testing.expectEqualSlices(Option, &.{ .confirm_remove, .cancel }, options(&local, true, &out));
}

test "taps map to rows and outside closes" {
    const y0: i32 = @intCast(top(3) + header);
    try std.testing.expectEqual(@as(usize, 0), hit(600, y0 + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 2), hit(600, y0 + 2 * row + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 3), hit(600, y0 - 20, 3).?);
    try std.testing.expect(hit(50, y0, 3) == null);
    try std.testing.expect(hit(600, 40, 3) == null);
}
