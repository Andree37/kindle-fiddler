//! Book list, read from the tab-separated file start.sh exports from the
//! Kindle's own database: path, title, author, percent, last opened.
const std = @import("std");
const cover = @import("cover.zig");
const text = @import("text.zig");

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
    finished: bool = false,
    thumbnail: [:0]const u8 = "",
    added: u64 = 0,
    cover: ?[]u8 = null,
    cover_tried: bool = false,

    pub fn status(e: Entry) Filter {
        if (e.finished or e.percent >= finished_percent) return .read;
        return if (e.percent == 0) .unread else .reading;
    }
};

pub const Filter = enum { all, unread, reading, read };

const finished_percent = 99;
const read_state_finished = 2; // Kindle's own "finished" mark

/// Converted filenames look like "Title -- Author -- Year -- junk".
pub fn cleanTitle(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " -- ") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
}

/// Filename conversion turned ":" into "_", and some titles carry a series prefix
/// like "[Bobiverse 01] \u{2022} We Are Legion".
pub fn fixTitle(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var t = cleanTitle(raw);
    const bullet = "\u{2022} ";
    if (t.len > 0 and t[0] == '[') {
        if (std.mem.indexOf(u8, t, bullet)) |at| t = t[at + bullet.len..];
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        if (std.mem.startsWith(u8, t[i..], " _ ")) {
            try out.appendSlice(alloc, ": ");
            i += 3;
        } else if (std.mem.startsWith(u8, t[i..], "_ ")) {
            try out.appendSlice(alloc, ": ");
            i += 2;
        } else {
            try out.append(alloc, t[i]);
            i += 1;
        }
    }
    return std.mem.trimEnd(u8, out.items, "_ ");
}

/// Authors can repeat as "Liu, Cixin [Liu, Cixin]".
pub fn cleanAuthor(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " [") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = fields.next() orelse continue;
        const title = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const percent = std.fmt.parseFloat(f32, fields.next() orelse "0") catch 0;
        const last = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const read_state = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
        const thumbnail = fields.next() orelse "";
        const added = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        if (path.len == 0) continue;
        try out.append(alloc, .{
            .path = try alloc.dupeSentinel(u8, path, 0),
            .title = try fixTitle(alloc, title),
            .author = cleanAuthor(author),
            .percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .last = last,
            // Taken here, before our own progress replaces the percent.
            .finished = read_state == read_state_finished or percent >= finished_percent,
            .thumbnail = try alloc.dupeSentinel(u8, thumbnail, 0),
            .added = added,
        });
    }
    return out.toOwnedSlice(alloc);
}

pub const Order = enum {
    recent,
    title,
    added,

    fn label(o: Order) []const u8 {
        return switch (o) {
            .recent => "Recent",
            .title => "Title",
            .added => "Added",
        };
    }

    pub fn next(o: Order) Order {
        return switch (o) {
            .recent => .title,
            .title => .added,
            .added => .recent,
        };
    }
};

fn before(order: Order, a: Entry, b: Entry) bool {
    return switch (order) {
        .recent => a.last > b.last,
        .added => a.added > b.added,
        .title => std.ascii.lessThanIgnoreCase(a.title, b.title),
    };
}

pub fn sort(entries: []Entry, order: Order) void {
    std.mem.sort(Entry, entries, order, before);
}

/// Fills `out` with indexes of matching entries and returns how many matched.
pub fn select(entries: []const Entry, filter: Filter, out: []usize) usize {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (filter == .all or e.status() == filter) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

pub const rows_per_page = 9;
const margin = 80;
const top = 150;
const row_height = 140;
const buttons_top = 1420;
const buttons_bottom = 1560;
// Between the bottom corners, where a holding thumb rests.
const prev_left = 300;
const sort_left = 520;
const next_left = 752;
const button_width = 220;
const exit_width = 300;

// Tabs start past the top-left corner, which is held to leave a book.
const Tab = struct { filter: Filter, label: []const u8, left: i32, right: i32 };
const tabs = [_]Tab{
    .{ .filter = .all, .label = "All", .left = 210, .right = 330 },
    .{ .filter = .unread, .label = "Unread", .left = 330, .right = 530 },
    .{ .filter = .reading, .label = "Reading", .left = 530, .right = 750 },
    .{ .filter = .read, .label = "Read", .left = 750, .right = 972 },
};

pub const Fonts = struct { title: *text.Font, small: *text.Font };

pub const Hit = union(enum) { none, book: usize, prev, next, sort, exit, tab: Filter };

pub fn pageCount(entries: usize) usize {
    return @max((entries + rows_per_page - 1) / rows_per_page, 1);
}

/// What a tap on this library page lands on.
pub fn hit(x: i32, y: i32, width: i32, page: usize, entries: usize) Hit {
    if (y < top) {
        if (x >= width - exit_width) return .exit;
        for (tabs) |t| {
            if (x >= t.left and x < t.right) return .{ .tab = t.filter };
        }
        return .none;
    }
    if (y >= buttons_top and y < buttons_bottom) {
        if (x >= prev_left and x < prev_left + button_width) return .prev;
        if (x >= sort_left and x < sort_left + button_width) return .sort;
        if (x >= next_left and x < next_left + button_width) return .next;
        return .none;
    }
    if (y >= top + rows_per_page * row_height) return .none;
    const row: usize = @intCast(@divTrunc(y - top, row_height));
    const index = page * rows_per_page + row;
    return if (index < entries) .{ .book = index } else .none;
}

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Screen area of a book row, for tap feedback.
pub fn rowRect(page: usize, index: usize, width: u32) Rect {
    const row: u32 = @intCast(index - page * rows_per_page);
    return .{ .x = 0, .y = top + row * row_height, .w = width, .h = row_height };
}

pub fn drawClipped(font: *text.Font, page: text.Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
    const w = try font.measure(s);
    if (w <= avail) return font.draw(page, x, y, s);
    const dots = "...";
    const cut = try font.fit(s, avail - try font.measure(dots));
    var buf: [256]u8 = undefined;
    const part = s[0..@min(cut, buf.len - dots.len)];
    @memcpy(buf[0..part.len], part);
    @memcpy(buf[part.len..][0..dots.len], dots);
    try font.draw(page, x, y, buf[0 .. part.len + dots.len]);
}

pub fn render(alloc: std.mem.Allocator, fonts: Fonts, page: text.Page, entries: []Entry, visible: []const usize, index: usize, filter: Filter, order: Order, message: []const u8) !void {
    @memset(page.buf, 0xff);
    const right: f32 = @floatFromInt(page.width - margin);
    for (tabs) |t| {
        const left: u32 = @intCast(t.left);
        const font = if (t.filter == filter) fonts.title else fonts.small;
        try font.draw(page, @floatFromInt(left), 100, t.label);
        if (t.filter == filter) page.fillRect(left, 116, @intFromFloat(try font.measure(t.label)), 6, 0x00);
    }
    try fonts.small.draw(page, right - 150, 100, "Kindle");
    page.fillRect(margin, top - 12, page.width - 2 * margin, 3, 0x00);

    const first = index * rows_per_page;
    const shown = visible[@min(first, visible.len)..@min(first + rows_per_page, visible.len)];
    for (shown, 0..) |entry_index, i| {
        const e = &entries[entry_index];
        const y: i32 = top + @as(i32, @intCast(i)) * row_height;
        if (!e.cover_tried) {
            e.cover_tried = true;
            if (e.thumbnail.len > 0) e.cover = cover.load(alloc, e.thumbnail);
        }
        const cover_y: u32 = @intCast(y + 6);
        if (e.cover) |c| {
            page.copyImage(margin, cover_y, c, cover.width, cover.height);
        } else {
            page.fillRect(margin, cover_y, cover.width, cover.height, 0xd0);
        }

        const left: f32 = margin + cover.width + 24;
        const avail: f32 = right - left - 110;
        try drawClipped(fonts.title, page, left, y + 58, e.title, avail);
        try drawClipped(fonts.small, page, left, y + 104, e.author, avail);

        var label: [8]u8 = undefined;
        const pct = std.fmt.bufPrint(&label, "{d}%", .{e.percent}) catch "";
        try fonts.small.draw(page, right - 90, y + 58, pct);

        const bar_y: u32 = @intCast(y + 124);
        const bar_x: u32 = @intFromFloat(left);
        const bar_w = page.width - margin - bar_x;
        page.fillRect(bar_x, bar_y, bar_w, 2, 0xc0);
        page.fillRect(bar_x, bar_y, bar_w * e.percent / 100, 6, 0x00);
    }

    try fonts.title.draw(page, prev_left + 20, buttons_top + 90, "Previous");
    try fonts.title.draw(page, next_left + 60, buttons_top + 90, "Next");
    try fonts.small.draw(page, sort_left + 50, buttons_top + 88, order.label());
    if (index == 0) page.dim(prev_left, buttons_top, button_width, buttons_bottom - buttons_top);
    if (index + 1 >= pageCount(visible.len)) page.dim(next_left, buttons_top, button_width, buttons_bottom - buttons_top);

    var label: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, pageCount(visible.len) }) catch "";
    try fonts.small.draw(page, @as(f32, @floatFromInt(page.width)) / 2 - 40, 1620, count);
    if (visible.len == 0) try fonts.small.draw(page, margin, top + 58, "No books here.");
    if (message.len > 0) try fonts.small.draw(page, margin, 1670, message);
}

test "titles lose filename junk" {
    try std.testing.expectEqualStrings("Snow Crash", cleanTitle("Snow Crash -- Stephenson, Neal -- 2010"));
    try std.testing.expectEqualStrings("Prisoners of Geography", cleanTitle("Prisoners of Geography"));
}

test "authors lose repeated names" {
    try std.testing.expectEqualStrings("Liu, Cixin", cleanAuthor("Liu, Cixin [Liu, Cixin]"));
}

test "rows parse and sort newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "/a.kfx\tOld -- x\tA\t12.7\t100\n/b.kfx\tNew\tB\t\t200\n\n";
    const rows = try parse(arena.allocator(), data);
    sort(rows, .recent);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("New", rows[0].title);
    try std.testing.expectEqual(@as(u32, 12), rows[1].percent);
    try std.testing.expectEqualStrings("Old", rows[1].title);
}

test "taps map to rows, buttons and exit" {
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(300, 200, 1272, 0, 79));
    try std.testing.expectEqual(Hit{ .book = 10 }, hit(300, 320, 1272, 1, 79));
    try std.testing.expectEqual(Hit.prev, hit(350, 1500, 1272, 0, 79));
    try std.testing.expectEqual(Hit.next, hit(800, 1500, 1272, 0, 79));
    try std.testing.expectEqual(Hit.exit, hit(1100, 80, 1272, 0, 79));
    try std.testing.expectEqual(Hit.none, hit(100, 80, 1272, 0, 79));
}

test "tapping past the last book does nothing" {
    try std.testing.expectEqual(Hit.none, hit(300, 200, 1272, 8, 72));
}

test "page count rounds up and is never zero" {
    try std.testing.expectEqual(@as(usize, 9), pageCount(79));
    try std.testing.expectEqual(@as(usize, 1), pageCount(0));
}

test "status uses kindle's finished mark over a lower percent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "/a\tA\tx\t99.1\t1\t1\n/b\tB\tx\t40\t1\t2\n/c\tC\tx\t40\t1\t1\n/d\tD\tx\t0\t1\t0\n");
    rows[0].percent = 3; // Reopened here, so our own progress replaced it
    try std.testing.expectEqual(Filter.read, rows[0].status());
    try std.testing.expectEqual(Filter.read, rows[1].status());
    try std.testing.expectEqual(Filter.reading, rows[2].status());
    try std.testing.expectEqual(Filter.unread, rows[3].status());
}

test "select keeps only matching books" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "A", .author = "", .percent = 0, .last = 0 },
        .{ .path = "/b", .title = "B", .author = "", .percent = 50, .last = 0 },
        .{ .path = "/c", .title = "C", .author = "", .percent = 0, .last = 0, .finished = true },
    };
    var out: [3]usize = undefined;
    try std.testing.expectEqual(@as(usize, 3), select(&rows, .all, &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .unread, &out));
    try std.testing.expectEqual(@as(usize, 0), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, &out));
    try std.testing.expectEqual(@as(usize, 2), out[0]);
}

test "tabs stay out of the top-left hold corner" {
    try std.testing.expectEqual(Hit.none, hit(150, 80, 1272, 0, 79));
    try std.testing.expectEqual(Hit{ .tab = .all }, hit(250, 80, 1272, 0, 79));
    try std.testing.expectEqual(Hit{ .tab = .unread }, hit(400, 80, 1272, 0, 79));
    try std.testing.expectEqual(Hit{ .tab = .reading }, hit(600, 80, 1272, 0, 79));
    try std.testing.expectEqual(Hit{ .tab = .read }, hit(800, 80, 1272, 0, 79));
    try std.testing.expectEqual(Hit.exit, hit(1000, 80, 1272, 0, 79));
}

test "titles get colons and lose series prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("The Butcher's Masquerade: Dungeon Crawler Carl (Book 5)", try fixTitle(a, "The Butcher's Masquerade_ Dungeon Crawler Carl (Book 5) -- Matt Dinniman"));
    try std.testing.expectEqualStrings("Streaming Data: Understanding the Real-time Pipeline", try fixTitle(a, "Streaming Data _ Understanding the Real-time Pipeline -- Andrew"));
    try std.testing.expectEqualStrings("Why Look at Animals", try fixTitle(a, "Why Look at Animals_ -- John Berger"));
    try std.testing.expectEqualStrings("We Are Legion", try fixTitle(a, "[Bobiverse 01] \u{2022} We Are Legion -- Taylor"));
    try std.testing.expectEqualStrings("file_name", try fixTitle(a, "file_name"));
}

test "sort orders by title and by date added" {
    var rows = [_]Entry{
        .{ .path = "/a", .title = "banana", .author = "", .percent = 0, .last = 1, .added = 5 },
        .{ .path = "/b", .title = "Apple", .author = "", .percent = 0, .last = 2, .added = 9 },
        .{ .path = "/c", .title = "cherry", .author = "", .percent = 0, .last = 3, .added = 1 },
    };
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Apple", rows[0].title);
    try std.testing.expectEqualStrings("cherry", rows[2].title);
    sort(&rows, .added);
    try std.testing.expectEqualStrings("Apple", rows[0].title);
    try std.testing.expectEqualStrings("cherry", rows[2].title);
    sort(&rows, .recent);
    try std.testing.expectEqualStrings("cherry", rows[0].title);
}

test "sort button cycles and sits between page buttons" {
    try std.testing.expectEqual(Order.title, Order.recent.next());
    try std.testing.expectEqual(Order.recent, Order.added.next());
    try std.testing.expectEqual(Hit.sort, hit(600, 1500, 1272, 0, 79));
}
