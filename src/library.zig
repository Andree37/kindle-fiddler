//! Book list, read from the tab-separated file start.sh exports from the
//! Kindle's own database: path, title, author, percent, last opened.
const std = @import("std");
const cover = @import("cover.zig");
const icons = @import("icons.zig");
const system = @import("system.zig");
const text = @import("text.zig");

pub const Availability = enum { local, cloud, downloading };

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
    finished: bool = false,
    kindle_percent: u32 = 0,
    kindle_last: u64 = 0,
    thumbnail: [:0]const u8 = "",
    added: u64 = 0,
    availability: Availability = .local,
    cover: ?[]u8 = null,
    cover_tried: bool = false,
    hero: ?[]u8 = null,
    hero_tried: bool = false,

    pub fn isRead(e: Entry) bool {
        return e.finished or e.percent >= finished_percent;
    }

    /// Started but not finished, which is what the hero leads with.
    pub fn inProgress(e: Entry) bool {
        return !e.isRead() and e.percent > 0;
    }

    /// On this Kindle and complete, so it can be opened.
    pub fn isLocal(e: Entry) bool {
        return e.availability == .local;
    }
};

pub const Filter = enum { all, unread, read };

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
        const availability: Availability = switch (std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0) {
            1 => .cloud,
            2 => .downloading,
            else => .local,
        };
        if (path.len == 0 and availability == .local) continue;
        try out.append(alloc, .{
            .path = try alloc.dupeSentinel(u8, path, 0),
            .title = try fixTitle(alloc, title),
            .author = cleanAuthor(author),
            .percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .last = last,
            // Taken here, before our own progress replaces the percent.
            .finished = read_state == read_state_finished or percent >= finished_percent,
            .kindle_percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .kindle_last = last,
            .thumbnail = try alloc.dupeSentinel(u8, thumbnail, 0),
            .added = added,
            .availability = availability,
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
            .title => "A to Z",
            .added => "Newest",
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

/// The book for the hero: the latest one in progress, or else the latest opened.
pub fn pickHero(entries: []const Entry) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |e, i| {
        if (!e.inProgress() or !e.isLocal()) continue;
        if (best == null or e.last > entries[best.?].last) best = i;
    }
    if (best != null) return best;
    for (entries, 0..) |e, i| {
        if (!e.isLocal()) continue;
        if (best == null or e.last > entries[best.?].last) best = i;
    }
    return best;
}

/// Fills `out` with indexes of matching entries, leaving out the hero, and returns how many.
pub fn select(entries: []const Entry, filter: Filter, hero: ?usize, out: []usize) usize {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (i == hero) continue;
        const matches = switch (filter) {
            .all => true,
            .read => e.isRead(),
            .unread => !e.isRead(),
        };
        if (matches) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

const margin = 72;
const gutter = 40;
const columns = 4;
const cell_step = cover.width + gutter;
const row_height = 410;
const status_height = 96;

// Page one always leads with the current book, on every tab and sort.
const hero_top = 112;
const hero_bottom = 500;
const hero_tabs_top = 516;
const hero_grid_top = 622;
const plain_tabs_top = 100;
const plain_grid_top = 206;
const tabs_height = 84;
const hero_rows = 2;
const plain_rows = 3;

const Tab = struct { filter: Filter, label: []const u8, left: i32, right: i32 };
const tabs = [_]Tab{
    .{ .filter = .all, .label = "All", .left = 72, .right = 170 },
    .{ .filter = .unread, .label = "Unread", .left = 170, .right = 352 },
    .{ .filter = .read, .label = "Read", .left = 352, .right = 500 },
};

const footer_top = 1450;
const footer_bottom = 1570;
const prev_left = 340;
const next_left = 732;
const footer_button = 200;
const sort_left = 860;

pub const Fonts = struct {
    title: *text.Font, // UI bold
    small: *text.Font, // UI regular
    caption: *text.Font,
    hero: *text.Font, // Book title, in the reading typeface
    cover: *text.Font,
};

pub const Hit = union(enum) { none, hero, book: usize, prev, next, sort, menu, tab: Filter };

fn gridSize(hero: bool) usize {
    return (if (hero) @as(usize, hero_rows) else plain_rows) * columns;
}

/// Index of the first grid book on a page.
fn firstBook(page: usize) usize {
    if (page == 0) return 0;
    return gridSize(true) + (page - 1) * gridSize(false);
}

pub fn pageCount(books: usize) usize {
    if (books <= gridSize(true)) return 1;
    return 1 + (books - gridSize(true) + gridSize(false) - 1) / gridSize(false);
}

fn tabsTop(hero: bool) i32 {
    return if (hero) hero_tabs_top else plain_tabs_top;
}

fn gridTop(hero: bool) i32 {
    return if (hero) hero_grid_top else plain_grid_top;
}

/// What a tap on this library page lands on.
pub fn hit(x: i32, y: i32, page: usize, books: usize) Hit {
    const hero = page == 0;
    if (y < status_height) return if (x < 220) .menu else .none;
    if (hero and y >= hero_top and y < hero_bottom) return .hero;

    const tabs_top = tabsTop(hero);
    if (y >= tabs_top and y < tabs_top + tabs_height) {
        if (x >= sort_left) return .sort;
        for (tabs) |t| {
            if (x >= t.left and x < t.right) return .{ .tab = t.filter };
        }
        return .none;
    }
    if (y >= footer_top and y < footer_bottom) {
        if (x >= prev_left and x < prev_left + footer_button) return .prev;
        if (x >= next_left and x < next_left + footer_button) return .next;
        return .none;
    }
    const top = gridTop(hero);
    if (y < top or x < margin) return .none;
    const column: usize = @intCast(@divTrunc(x - margin, cell_step));
    const row: usize = @intCast(@divTrunc(y - top, row_height));
    if (column >= columns or row >= gridSize(hero) / columns) return .none;
    const index = firstBook(page) + row * columns + column;
    return if (index < books) .{ .book = index } else .none;
}

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Screen area of the hero, for tap feedback.
pub fn heroRect(width: u32) Rect {
    return .{ .x = margin, .y = hero_top, .w = width - 2 * margin, .h = cover.hero_height };
}

/// Screen area of a grid book, for tap feedback.
pub fn bookRect(index: usize, page: usize) Rect {
    const offset = index - firstBook(page);
    const column: u32 = @intCast(offset % columns);
    const row: u32 = @intCast(offset / columns);
    const top: u32 = @intCast(gridTop(page == 0));
    return .{ .x = margin + column * cell_step, .y = top + row * row_height, .w = cover.width, .h = cover.height };
}

pub fn drawClipped(font: *text.Font, page: text.Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
    const w = try font.measure(s);
    if (w <= avail) return font.draw(page, x, y, s);
    const dots = "...";
    const cut = try font.fit(s, avail - try font.measure(dots));
    var buf: [256]u8 = undefined;
    const part = std.mem.trimEnd(u8, s[0..@min(cut, buf.len - dots.len)], " ");
    @memcpy(buf[0..part.len], part);
    @memcpy(buf[part.len..][0..dots.len], dots);
    try font.draw(page, x, y, buf[0 .. part.len + dots.len]);
}

/// Bytes of `s` that fit on one line, breaking at a space when possible.
fn lineBreak(font: *text.Font, s: []const u8, avail: f32) !usize {
    if (try font.measure(s) <= avail) return s.len;
    const cut = try font.fit(s, avail);
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |space| {
        if (space > 0) return space;
    }
    return cut;
}

/// Wraps text over at most `lines`, clipping the last, and returns the lines used.
fn drawWrapped(font: *text.Font, page: text.Page, x: f32, y: i32, step: i32, s: []const u8, avail: f32, lines: u32) !u32 {
    var rest = s;
    var line: u32 = 0;
    while (rest.len > 0 and line < lines) : (line += 1) {
        const row = y + @as(i32, @intCast(line)) * step;
        if (line + 1 == lines) {
            try drawClipped(font, page, x, row, rest, avail);
            return line + 1;
        }
        const n = try lineBreak(font, rest, avail);
        try font.draw(page, x, row, rest[0..n]);
        rest = std.mem.trimStart(u8, rest[n..], " ");
    }
    return line;
}

fn progressBar(page: text.Page, x: u32, y: u32, w: u32, percent: u32) void {
    page.fillRect(x, y + 2, w, 2, 0xc0);
    page.fillRect(x, y, w * @min(percent, 100) / 100, 6, 0x00);
}

/// A book with no thumbnail still gets a real cover: its title set in type.
fn typeCover(fonts: Fonts, page: text.Page, x: u32, y: u32, w: u32, h: u32, e: *const Entry) !void {
    page.fillRect(x, y, w, h, 0xf0);
    page.fillRect(x, y, w, 2, 0x00);
    page.fillRect(x, y + h - 2, w, 2, 0x00);
    page.fillRect(x, y, 2, h, 0x00);
    page.fillRect(x + w - 2, y, 2, h, 0x00);
    const left: f32 = @floatFromInt(x + 28);
    const avail: f32 = @floatFromInt(w - 56);
    const top: i32 = @intCast(y + 72);
    const used = try drawWrapped(fonts.cover, page, left, top, 44, e.title, avail, 5);
    page.fillRect(x + 28, y + 72 + used * 44, 48, 3, 0x00);
    try drawClipped(fonts.caption, page, left, @intCast(y + h - 34), e.author, avail);
}

fn drawCover(alloc: std.mem.Allocator, fonts: Fonts, page: text.Page, e: *Entry, x: u32, y: u32) !void {
    if (!e.cover_tried) {
        e.cover_tried = true;
        if (e.thumbnail.len > 0) e.cover = cover.load(alloc, e.thumbnail, cover.width, cover.height);
    }
    if (e.cover) |c| {
        page.copyImage(x, y, c, cover.width, cover.height);
    } else {
        try typeCover(fonts, page, x, y, cover.width, cover.height, e);
    }
}

fn drawHero(alloc: std.mem.Allocator, fonts: Fonts, page: text.Page, e: *Entry) !void {
    if (!e.hero_tried) {
        e.hero_tried = true;
        if (e.thumbnail.len > 0) e.hero = cover.load(alloc, e.thumbnail, cover.hero_width, cover.hero_height);
    }
    if (e.hero) |c| {
        page.copyImage(margin, hero_top, c, cover.hero_width, cover.hero_height);
    } else {
        try typeCover(fonts, page, margin, hero_top, cover.hero_width, cover.hero_height, e);
    }

    const left_px: u32 = margin + cover.hero_width + 48;
    const left: f32 = @floatFromInt(left_px);
    const avail: f32 = @floatFromInt(page.width - left_px - margin);
    try fonts.caption.draw(page, left, hero_top + 34, "Continue reading");
    page.tint(left_px, hero_top + 8, @intFromFloat(avail), 36, 0x60);

    const used = try drawWrapped(fonts.hero, page, left, hero_top + 104, 66, e.title, avail, 3);
    const author_y: i32 = hero_top + 104 + @as(i32, @intCast(used)) * 66 - 12;
    try drawClipped(fonts.small, page, left, author_y, e.author, avail);
    page.tint(left_px, @intCast(author_y - 30), @intFromFloat(avail), 44, 0x50);

    const bar_y = hero_top + cover.hero_height - 40;
    progressBar(page, left_px, bar_y, @intFromFloat(avail), e.percent);
    var label: [24]u8 = undefined;
    const pct = std.fmt.bufPrint(&label, "{d}% read", .{e.percent}) catch "";
    try fonts.caption.draw(page, left, bar_y + 42, pct);
    page.tint(left_px, bar_y + 16, @intFromFloat(avail), 34, 0x50);
}

fn drawCell(alloc: std.mem.Allocator, fonts: Fonts, page: text.Page, e: *Entry, x: u32, y: u32) !void {
    try drawCover(alloc, fonts, page, e, x, y);
    const bar_y = y + cover.height + 8;
    if (!e.isLocal()) {
        page.tint(x, y, cover.width, cover.height, 0xa0);
        icons.cloud(page, @floatFromInt(x + cover.width - 38), @floatFromInt(y + cover.height - 38));
        const label = if (e.availability == .downloading) "Downloading" else e.title;
        _ = try drawWrapped(fonts.caption, page, @floatFromInt(x), @intCast(bar_y + 34), 30, label, cover.width, 1);
        return;
    }
    if (e.inProgress()) progressBar(page, x, bar_y, cover.width, e.percent);
    if (e.isRead()) icons.check(page, @floatFromInt(x + cover.width - 32), @floatFromInt(y + 32));
    _ = try drawWrapped(fonts.caption, page, @floatFromInt(x), @intCast(bar_y + 34), 30, e.title, cover.width, 1);
}

fn drawStatus(fonts: Fonts, page: text.Page, quick: *const system.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    // One centre line for everything in the strip.
    const centre = 48;
    const baseline = centre + 9;
    icons.menu(page, margin, centre - 14);
    const clock = quick.clockText();
    const time = clock[0 .. std.mem.indexOfScalar(u8, clock, ' ') orelse clock.len];
    const tw = try fonts.caption.measure(time);
    try fonts.caption.draw(page, w / 2 - tw / 2, baseline, time);
    try icons.statusCluster(page, fonts.caption, w - margin, centre, baseline, quick, false);
}

fn drawTabs(fonts: Fonts, page: text.Page, top: i32, filter: Filter, order: Order) !void {
    const y = top + 54;
    for (tabs) |t| {
        const left: u32 = @intCast(t.left);
        const active = t.filter == filter;
        const font = if (active) fonts.title else fonts.small;
        try font.draw(page, @floatFromInt(left), y, t.label);
        if (active) {
            const width: u32 = @intFromFloat(try font.measure(t.label));
            page.fillRect(left, @intCast(top + tabs_height - 8), width, 5, 0x00);
        } else {
            page.tint(left, @intCast(top + 16), @intCast(t.right - t.left - 4), 50, 0x50);
        }
    }
    const right: f32 = @floatFromInt(page.width - margin);
    const sort_w = try fonts.small.measure(order.label());
    try fonts.small.draw(page, right - sort_w, y, order.label());
    page.fillRect(margin, @intCast(top + tabs_height - 4), page.width - 2 * margin, 1, 0xb0);
}

fn drawFooter(fonts: Fonts, page: text.Page, index: usize, pages: usize) !void {
    const centre = @as(f32, @floatFromInt(page.width)) / 2;
    const y = (footer_top + footer_bottom) / 2 + 12;
    var label: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&label, "{d} of {d}", .{ index + 1, pages }) catch "";
    const w = try fonts.small.measure(count);
    try fonts.small.draw(page, centre - w / 2, y, count);
    const mid: f32 = @floatFromInt(y - 11);
    const prev_x: f32 = prev_left + footer_button / 2;
    const next_x: f32 = next_left + footer_button / 2;
    page.stroke(prev_x + 9, mid - 18, prev_x - 9, mid, 4);
    page.stroke(prev_x - 9, mid, prev_x + 9, mid + 18, 4);
    page.stroke(next_x - 9, mid - 18, next_x + 9, mid, 4);
    page.stroke(next_x + 9, mid, next_x - 9, mid + 18, 4);
    if (index == 0) page.tint(prev_left, footer_top, footer_button, footer_bottom - footer_top, 0xc8);
    if (index + 1 >= pages) page.tint(next_left, footer_top, footer_button, footer_bottom - footer_top, 0xc8);
}

pub fn render(alloc: std.mem.Allocator, fonts: Fonts, page: text.Page, entries: []Entry, hero: ?usize, visible: []const usize, index: usize, filter: Filter, order: Order, message: []const u8, quick: *const system.Quick) !void {
    @memset(page.buf, 0xff);
    try drawStatus(fonts, page, quick);

    const with_hero = index == 0;
    if (with_hero) {
        if (hero) |h| try drawHero(alloc, fonts, page, &entries[h]);
    }
    try drawTabs(fonts, page, tabsTop(with_hero), filter, order);

    const first = firstBook(index);
    const shown = visible[@min(first, visible.len)..@min(first + gridSize(with_hero), visible.len)];
    const top: u32 = @intCast(gridTop(with_hero));
    for (shown, 0..) |entry_index, i| {
        const x: u32 = margin + @as(u32, @intCast(i % columns)) * cell_step;
        const y: u32 = top + @as(u32, @intCast(i / columns)) * row_height;
        try drawCell(alloc, fonts, page, &entries[entry_index], x, y);
    }
    if (visible.len == 0) try fonts.small.draw(page, margin, @intCast(top + 60), "No books here yet.");
    try drawFooter(fonts, page, index, pageCount(visible.len));
    if (message.len > 0) try fonts.caption.draw(page, margin, 1640, message);
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

test "sort button cycles" {
    try std.testing.expectEqual(Order.title, Order.recent.next());
    try std.testing.expectEqual(Order.recent, Order.added.next());
}

test "the current book stays on page one of every view" {
    try std.testing.expectEqual(Hit.hero, hit(300, 200, 0, 79));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(100, 700, 0, 79));
    try std.testing.expectEqual(Hit{ .book = 3 }, hit(1000, 700, 0, 79));
    try std.testing.expectEqual(Hit{ .book = 4 }, hit(100, 1100, 0, 79));
}

test "later pages are four by three" {
    try std.testing.expectEqual(Hit{ .book = 8 }, hit(100, 300, 1, 79));
    try std.testing.expectEqual(Hit{ .book = 19 }, hit(1000, 1100, 1, 79));
}

test "header and footer controls" {
    try std.testing.expectEqual(Hit.menu, hit(100, 50, 0, 79));
    try std.testing.expectEqual(Hit{ .tab = .unread }, hit(250, 560, 0, 79));
    try std.testing.expectEqual(Hit{ .tab = .read }, hit(400, 560, 0, 79));
    try std.testing.expectEqual(Hit.none, hit(600, 560, 0, 79));
    try std.testing.expectEqual(Hit.sort, hit(1100, 560, 0, 79));
    try std.testing.expectEqual(Hit.prev, hit(400, 1500, 0, 79));
    try std.testing.expectEqual(Hit.next, hit(800, 1500, 0, 79));
}

test "tapping past the last book does nothing" {
    try std.testing.expectEqual(Hit.none, hit(1000, 1100, 0, 3));
}

test "page count follows the layout" {
    try std.testing.expectEqual(@as(usize, 1), pageCount(0));
    try std.testing.expectEqual(@as(usize, 1), pageCount(8));
    try std.testing.expectEqual(@as(usize, 2), pageCount(9));
    try std.testing.expectEqual(@as(usize, 7), pageCount(78));
}

test "finished stays read after our progress replaces the percent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "/a\tA\tx\t99.1\t1\t1\n/b\tB\tx\t40\t1\t2\n/c\tC\tx\t40\t1\t1\n/d\tD\tx\t0\t1\t0\n");
    rows[0].percent = 3;
    try std.testing.expect(rows[0].isRead());
    try std.testing.expect(rows[1].isRead());
    try std.testing.expect(!rows[2].isRead());
    try std.testing.expect(rows[2].inProgress());
    try std.testing.expect(!rows[3].inProgress());
}

test "hero is the latest book in progress, and leaves the grid" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Done", .author = "", .percent = 99, .last = 3 },
        .{ .path = "/b", .title = "Fresh", .author = "", .percent = 0, .last = 2 },
        .{ .path = "/c", .title = "Now", .author = "", .percent = 34, .last = 1 },
    };
    const hero = pickHero(&rows);
    try std.testing.expectEqual(@as(usize, 2), hero.?);
    var out: [3]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), select(&rows, .all, hero, &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .unread, hero, &out));
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, hero, &out));
    try std.testing.expectEqual(@as(usize, 0), out[0]);
}

test "with nothing in progress the hero is the latest opened" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Old", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "New", .author = "", .percent = 0, .last = 5 },
    };
    try std.testing.expectEqual(@as(usize, 1), pickHero(&rows).?);
}

test "cloud books list without a path and never lead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "\tCloud\tx\t50\t9\t0\t\t1\t1\n/b\tHere\tx\t20\t1\t0\t\t1\t0\n/c\tGetting\tx\t0\t2\t0\t\t1\t2\n\tNoPath\tx\t0\t2\t0\t\t1\t0\n");
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(Availability.cloud, rows[0].availability);
    try std.testing.expectEqual(Availability.downloading, rows[2].availability);
    try std.testing.expectEqual(@as(usize, 1), pickHero(rows).?);
}
