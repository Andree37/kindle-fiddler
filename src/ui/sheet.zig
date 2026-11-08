//! Actions for one book, opened from the three dots beside its cover. Shown as a card.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const stats = @import("../model/stats.zig");
const catalog = @import("../model/catalog.zig");
const card = @import("card.zig");
const cover = @import("../gfx/image.zig");
const library = @import("library.zig");

pub const Option = enum { download, remove, mark_read, mark_unread, confirm_remove, cancel };

/// What a book offers. `confirming` swaps the list for the removal question.
/// The card's rows for a list of options.
pub fn rows(list: []const Option, out: []card.Row) []card.Row {
    for (list, out[0..list.len]) |o, *r| r.* = .{ .label = label(o), .quiet = o == .cancel };
    return out[0..list.len];
}

/// The line under the title: the author and time read, or what removal means.
pub fn subtitle(buf: []u8, e: *const catalog.Entry, confirming: bool) []const u8 {
    if (confirming) return "It stays in your Amazon library.";
    if (e.seconds_read < 60) return e.author;
    var time_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}  \u{b7}  read for {s}", .{ e.author, stats.formatMinutes(&time_buf, e.seconds_read / 60) }) catch e.author;
}

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

pub fn label(o: Option) []const u8 {
    return switch (o) {
        .download => "Download",
        .remove => "Remove download",
        .mark_read => "Mark as read",
        .mark_unread => "Mark as unread",
        .confirm_remove => "Remove from this Kindle",
        .cancel => "Cancel",
    };
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

