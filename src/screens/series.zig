//! Setting a book's series by hand, from its actions sheet: pick one of the library's
//! series, or type a new one, or none; then the book's number in it. Saved in the
//! data folder's "series" file, which wins over what file names say.
const std = @import("std");
const catalog = @import("../model/catalog.zig");
const overrides = @import("../model/series_override.zig");
const search = @import("../model/search.zig");
const goto_ui = @import("../ui/goto.zig");
const keyboard = @import("../ui/keyboard.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const draw = @import("../ui/draw.zig");
const icons = @import("../ui/icons.zig");
const style = @import("../ui/style.zig");
const state = @import("../linux/state.zig");
const app = @import("../app.zig");

const numbers = 30; // Places offered in a series: 1 to 30

/// The overrides file in the data folder.
pub fn path(buf: []u8, state_dir: []const u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/series", .{state_dir}, 0);
}

/// Applies the hand-set series to the library's entries.
pub fn apply(alloc: std.mem.Allocator, state_dir: []const u8, entries: []catalog.Entry) void {
    var path_buf: [320]u8 = undefined;
    const p = path(&path_buf, state_dir) catch return;
    var buf: [64 * 1024]u8 = undefined;
    const list = overrides.parse(alloc, state.readSmall(p, &buf)) catch return;
    for (entries) |*e| {
        const o = overrides.find(list, e.path) orelse continue;
        e.series = alloc.dupe(u8, o.name) catch continue;
        e.series_index = o.index;
    }
}

/// One page of choices under a heading, until one is tapped: its index, or null when
/// the header is tapped or the Kindle locks.
fn pick(a: *app.App, heading: []const u8, about: []const u8, rows: []const goto_ui.Row) !?usize {
    var list_page: usize = 0;
    while (true) {
        const page = a.page(a.screen.pixels);
        page.fillRect(0, 0, page.width, page.height, style.white);
        // Back to the library along the top, as the stats screen has it; the heading
        // large under it, and the book it's for
        icons.back(page, style.margin + 18, 70);
        try a.ui.small.draw(page, style.margin + 56, 82, "Library");
        const avail: f32 = @floatFromInt(page.width - 2 * style.margin);
        try draw.clipped(a.ui.hero, page, style.margin, 222, heading, avail);
        try draw.clipped(a.ui.caption, page, style.margin, 278, about, avail);
        page.tint(style.margin, 250, page.width - 2 * style.margin, 36, style.faded);
        try goto_ui.renderList(a.ui, page, rows, null, list_page, "");
        try a.showBand(0, a.screen.height);
        const choice = while (true) {
            const action = a.input.next();
            switch (action) {
                .tap => |t| switch (goto_ui.hit(t.x, t.y, list_page, rows.len)) {
                    .none, .tab => continue,
                    else => |h| break h,
                },
                .lock, .power, .computer, .stop => {
                    a.input.stashed = action;
                    return null;
                },
                else => {},
            }
        };
        switch (choice) {
            .close, .none, .tab => return null,
            .row => |i| return i,
            .prev => list_page -|= 1,
            .next => list_page = @min(list_page + 1, goto_ui.pageCount(rows.len) - 1),
        }
    }
}

/// A new series' name, typed. Null if cancelled.
fn typeName(a: *app.App, alloc: std.mem.Allocator) !?[]const u8 {
    var q = search.Query{};
    var first = true;
    while (true) {
        const page = a.page(a.screen.pixels);
        try search_sheet.renderBar(a.ui, page, 0, q.slice(), "Series name", .none);
        if (first) keyboard.render(a.ui, page) catch {};
        try a.showBand(0, if (first) a.screen.height else keyboard.top);
        first = false;
        const action = a.input.next();
        switch (action) {
            .tap => |t| {
                if (keyboard.hit(t.x, t.y)) |k| switch (k) {
                    .char => |c| q.push(c),
                    .space => q.push(' '),
                    .backspace => q.pop(),
                    .enter => if (q.words().len > 0) return try overrides.titleCase(alloc, q.slice()),
                } else if (search_sheet.hit(t.x, t.y, 0) == .cancel) return null;
            },
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                return null;
            },
            else => {},
        }
    }
}

fn byName(_: void, x: []const u8, y: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(x, y);
}

/// Sets `e`'s series by hand. True when it changed; what was on screen is the
/// caller's to redraw either way.
pub fn choose(a: *app.App, entries: []const catalog.Entry, e: *const catalog.Entry) !bool {
    var arena = std.heap.ArenaAllocator.init(a.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The library's series, once each, by name
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |o| {
        if (o.series.len == 0) continue;
        const seen = for (names.items) |n| {
            if (catalog.sameSeries(n, o.series)) break true;
        } else false;
        if (!seen) try names.append(alloc, o.series);
    }
    std.mem.sort([]const u8, names.items, {}, byName);
    var rows: std.ArrayList(goto_ui.Row) = .empty;
    try rows.append(alloc, .{ .label = "New series\u{2026}", .page = 0, .note = "" });
    try rows.append(alloc, .{ .label = "Not in a series", .page = 0, .note = "" });
    for (names.items) |n| try rows.append(alloc, .{ .label = n, .page = 0, .note = if (catalog.sameSeries(n, e.series)) "Now" else "" });

    const picked = try pick(a, "Series", e.title, rows.items) orelse return false;
    var name: []const u8 = "";
    var index: f32 = 0;
    if (picked == 0) {
        name = try typeName(a, alloc) orelse return false;
    } else if (picked >= 2) {
        name = names.items[picked - 2];
    }
    if (name.len > 0) {
        // Its number, with the books already at each place shown beside it
        var number_rows: [numbers]goto_ui.Row = undefined;
        for (&number_rows, 1..) |*r, n| {
            var taken: []const u8 = "";
            for (entries) |o| {
                if (catalog.sameSeries(o.series, name) and o.series_index == @as(f32, @floatFromInt(n)) and !std.mem.eql(u8, o.path, e.path)) taken = o.title;
            }
            r.* = .{ .label = try std.fmt.allocPrint(alloc, "#{d}  {s}", .{ n, taken }), .page = 0, .note = "" };
        }
        const heading = try std.fmt.allocPrint(alloc, "Number in {s}", .{name});
        const n = try pick(a, heading, e.title, &number_rows) orelse return false;
        index = @floatFromInt(n + 1);
    }

    var path_buf: [320]u8 = undefined;
    const p = try path(&path_buf, a.state_dir);
    var buf: [64 * 1024]u8 = undefined;
    const list = try overrides.parse(alloc, state.readSmall(p, &buf));
    state.writeSmall(p, try overrides.format(alloc, list, e.path, name, index));
    std.debug.print("series set: {s} #{d}\n", .{ if (name.len > 0) name else "(none)", index });
    return true;
}
