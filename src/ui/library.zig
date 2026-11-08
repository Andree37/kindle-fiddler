//! Book list, read from the tab-separated file start.sh exports from the
//! Kindle's own database: path, title, author, percent, last opened.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const draw = @import("draw.zig");
const style = @import("style.zig");
const cover = @import("../gfx/image.zig");
const icons = @import("icons.zig");
const quick_model = @import("../model/quick.zig");
const text = @import("../layout/text.zig");
const catalog = @import("../model/catalog.zig");
const Fonts = @import("fonts.zig").Fonts;

const margin = style.margin;
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

const Tab = struct { filter: catalog.Filter, label: []const u8, left: i32, right: i32 };
const tabs = [_]Tab{
    .{ .filter = .all, .label = "All", .left = 72, .right = 170 },
    .{ .filter = .unread, .label = "Unread", .left = 170, .right = 352 },
    .{ .filter = .read, .label = "Read", .left = 352, .right = 500 },
};

const footer = draw.Pager{ .top = 1450, .bottom = 1570 };
const sort_left = 860;

pub const Hit = union(enum) { none, hero, hero_dots, book: usize, dots: usize, prev, next, sort, menu, tab: catalog.Filter };

fn gridSize(hero: bool) usize {
    return (if (hero) @as(usize, hero_rows) else plain_rows) * columns;
}

/// Index of the first grid book on a page.
fn firstBook(page: usize) usize {
    if (page == 0) return 0;
    return gridSize(true) + (page - 1) * gridSize(false);
}

/// Range of grid books on a page, for logging what's shown.
pub fn pageRange(page: usize, books: usize) struct { first: usize, end: usize } {
    const first = @min(firstBook(page), books);
    return .{ .first = first, .end = @min(first + gridSize(page == 0), books) };
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
    if (hero and y >= hero_top and y < hero_bottom) {
        if (x >= 1100 and y < hero_top + 90) return .hero_dots;
        return .hero;
    }

    const tabs_top = tabsTop(hero);
    if (y >= tabs_top and y < tabs_top + tabs_height) {
        if (x >= sort_left) return .sort;
        for (tabs) |t| {
            if (x >= t.left and x < t.right) return .{ .tab = t.filter };
        }
        return .none;
    }
    if (footer.hit(x, y)) |h| return switch (h) {
        .prev => .prev,
        .next => .next,
    };
    if (y >= footer.top and y < footer.bottom) return .none;
    const top = gridTop(hero);
    if (y < top or x < margin) return .none;
    const column: usize = @intCast(@divTrunc(x - margin, cell_step));
    const row: usize = @intCast(@divTrunc(y - top, row_height));
    if (column >= columns or row >= gridSize(hero) / columns) return .none;
    const index = firstBook(page) + row * columns + column;
    if (index >= books) return .none;
    const inside_x = @mod(x - margin, cell_step);
    const inside_y = @mod(y - top, row_height);
    if (inside_y >= cover.height and inside_x >= cover.width - 90) return .{ .dots = index };
    return .{ .book = index };
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

pub fn drawClipped(font: *Font, page: Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
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
fn lineBreak(font: *Font, s: []const u8, avail: f32) !usize {
    if (try font.measure(s) <= avail) return s.len;
    const cut = try font.fit(s, avail);
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |space| {
        if (space > 0) return space;
    }
    return cut;
}

/// Wraps text over at most `lines`, clipping the last, and returns the lines used.
fn drawWrapped(font: *Font, page: Page, x: f32, y: i32, step: i32, s: []const u8, avail: f32, lines: u32) !u32 {
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

fn progressBar(page: Page, x: u32, y: u32, w: u32, percent: u32) void {
    page.fillRect(x, y + 2, w, 2, 0xc0);
    page.fillRect(x, y, w * @min(percent, 100) / 100, 6, 0x00);
}

/// A book with no thumbnail still gets a real cover: its title set in type.
fn typeCover(fonts: Fonts, page: Page, x: u32, y: u32, w: u32, h: u32, e: *const catalog.Entry) !void {
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

fn drawCover(alloc: std.mem.Allocator, fonts: Fonts, page: Page, e: *catalog.Entry, x: u32, y: u32) !void {
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

fn drawHero(alloc: std.mem.Allocator, fonts: Fonts, page: Page, e: *catalog.Entry) !void {
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
    icons.dots(page, @floatFromInt(page.width - margin - 8), hero_top + 24);
    page.tint(left_px, hero_top + 8, @intFromFloat(avail - 40), 36, 0x60);

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

fn drawCell(alloc: std.mem.Allocator, fonts: Fonts, page: Page, e: *catalog.Entry, x: u32, y: u32) !void {
    try drawCover(alloc, fonts, page, e, x, y);
    const bar_y = y + cover.height + 8;
    const dots_x: f32 = @floatFromInt(x + cover.width - 8);
    const dots_y: f32 = @floatFromInt(bar_y + 26);
    icons.dots(page, dots_x, dots_y);
    const title_width: f32 = cover.width - 34;
    if (!e.isLocal()) {
        page.tint(x, y, cover.width, cover.height, 0xa0);
        icons.cloud(page, @floatFromInt(x + cover.width - 38), @floatFromInt(y + cover.height - 38));
        const label = if (e.availability == .downloading) "Downloading" else e.title;
        _ = try drawWrapped(fonts.caption, page, @floatFromInt(x), @intCast(bar_y + 34), 30, label, title_width, 1);
        return;
    }
    if (e.inProgress()) progressBar(page, x, bar_y, cover.width, e.percent);
    if (e.isRead()) icons.check(page, @floatFromInt(x + cover.width - 32), @floatFromInt(y + 32));
    _ = try drawWrapped(fonts.caption, page, @floatFromInt(x), @intCast(bar_y + 34), 30, e.title, title_width, 1);
}

fn drawStatus(fonts: Fonts, page: Page, quick: *const quick_model.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    // One centre line for everything in the strip.
    const centre = 48;
    const baseline = centre + 9;
    icons.menu(page, margin, centre - 14);
    const clock = quick.clockText();
    const time = clock[0 .. std.mem.indexOfScalar(u8, clock, ' ') orelse clock.len];
    try draw.centered(fonts.caption, page, w / 2, baseline, time);
    try icons.statusCluster(page, fonts.caption, w - margin, centre, baseline, quick, false);
}

fn drawTabs(fonts: Fonts, page: Page, top: i32, filter: catalog.Filter, order: catalog.Order) !void {
    const y = top + 54;
    for (tabs) |t| {
        const left: u32 = @intCast(t.left);
        const active = t.filter == filter;
        try draw.choice(fonts, page, @floatFromInt(left), .left, y, t.label, active, @intCast(top + tabs_height - 8));
        if (!active) page.tint(left, @intCast(top + 16), @intCast(t.right - t.left - 4), 50, style.faded);
    }
    const right: f32 = @floatFromInt(page.width - margin);
    const sort_w = try fonts.small.measure(order.label());
    try fonts.small.draw(page, right - sort_w, y, order.label());
    page.fillRect(margin, @intCast(top + tabs_height - 4), page.width - 2 * margin, 1, style.rule);
}

fn drawFooter(fonts: Fonts, page: Page, index: usize, pages: usize) !void {
    try footer.render(fonts, page, index, pages);
}

pub fn render(alloc: std.mem.Allocator, fonts: Fonts, page: Page, entries: []catalog.Entry, hero: ?usize, visible: []const usize, index: usize, filter: catalog.Filter, order: catalog.Order, message: []const u8, quick: *const quick_model.Quick) !void {
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

test "three dots sit beside the title" {
    try std.testing.expectEqual(Hit{ .dots = 0 }, hit(300, 975, 0, 79));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(120, 975, 0, 79));
    try std.testing.expectEqual(Hit.hero_dots, hit(1180, 130, 0, 79));
}
