//! The reader's three-dots menu: go to a page, back to the start, book details,
//! a screen refresh, and marking the book finished or unread.
const std = @import("std");
const card = @import("../../ui/card.zig");
const catalog = @import("../../model/catalog.zig");
const stats = @import("../../model/stats.zig");
const store = @import("../../kindle/store.zig");
const app = @import("../../app.zig");
const library_screen = @import("../library.zig");
const page_number = @import("page_number.zig");
const sess = @import("session.zig");

/// What the reader does after the menu.
pub const Result = union(enum) {
    stay, // Back to the toolbar
    page: usize, // Show this page
    refresh, // Show the current page with a full, clean refresh
};

const Option = enum { go_to_page, beginning, details, refresh, finished, unread, cancel };

fn label(o: Option) []const u8 {
    return switch (o) {
        .go_to_page => "Go to page\u{2026}",
        .beginning => "Go to beginning",
        .details => "Book details",
        .refresh => "Refresh screen",
        .finished => "Mark as finished",
        .unread => "Mark as unread",
        .cancel => "Cancel",
    };
}

pub fn run(a: *app.App, s: *sess.Session, entry: *catalog.Entry) !Result {
    const list = [_]Option{ .go_to_page, .beginning, .details, .refresh, if (entry.isRead()) .unread else .finished, .cancel };
    var rows: [list.len]card.Row = undefined;
    for (list, &rows) |o, *r| r.* = .{ .label = label(o), .quiet = o == .cancel };
    const background = try s.ensure(s.current, s.current);
    const picked = try app.chooseFromCard(a, background, entry.title, entry.author, &rows) orelse return .stay;
    switch (list[picked]) {
        .cancel => return .stay,
        .go_to_page => return if (try page_number.run(a, s)) |index| .{ .page = index } else .stay,
        .beginning => return .{ .page = 0 },
        .refresh => return .refresh,
        .details => {
            try details(a, s, entry, background);
            return .stay;
        },
        .finished, .unread => |choice| {
            const done = choice == .finished;
            store.markRead(entry.key, entry.kind, done);
            entry.finished = done;
            if (!done) library_screen.forgetFinished(a, entry) catch {};
            std.debug.print("marked {s}\n", .{if (done) "finished" else "unread"});
            return .stay;
        },
    }
}

/// A card of facts about the book. Any tap closes it.
fn details(a: *app.App, s: *sess.Session, entry: *const catalog.Entry, background: []const u8) !void {
    var progress_buf: [64]u8 = undefined;
    var read_buf: [64]u8 = undefined;
    var left_buf: [64]u8 = undefined;
    var counts_buf: [96]u8 = undefined;
    var t1: [32]u8 = undefined;
    var t2: [32]u8 = undefined;
    const percent = (s.current + 1) * 100 / s.pages.len;
    const highlights = countIds(s);
    const rows = [_]card.Row{
        .{ .quiet = true, .label = std.fmt.bufPrint(&progress_buf, "Page {d} of {d}, {d}%", .{ s.current + 1, s.pages.len, percent }) catch "" },
        .{ .quiet = true, .label = if (s.seconds_read >= 60) std.fmt.bufPrint(&read_buf, "Read for {s}", .{stats.formatMinutes(&t1, s.seconds_read / 60)}) catch "" else "Not read here yet" },
        .{ .quiet = true, .label = if (s.timeLeft(s.current).book) |m| std.fmt.bufPrint(&left_buf, "{s} left in the book", .{stats.formatMinutes(&t2, m)}) catch "" else "Learning your reading speed" },
        .{ .quiet = true, .label = std.fmt.bufPrint(&counts_buf, "{d} chapters, {d} highlights, {d} bookmarks", .{ s.chapters.len, highlights, s.bookmarks.items.len }) catch "" },
        .{ .label = "Close" },
    };
    _ = try app.chooseFromCard(a, background, entry.title, entry.author, &rows);
}

/// Highlights, counted once each though they're kept as a mark per paragraph.
fn countIds(s: *const sess.Session) usize {
    var n: usize = 0;
    for (s.highlights.items, 0..) |h, i| {
        var seen = false;
        for (s.highlights.items[0..i]) |earlier| seen = seen or std.mem.eql(u8, earlier.id, h.id);
        if (!seen) n += 1;
    }
    return n;
}
