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
// Inside one rounded button that starts with a funnel; `left` and `right` bound the taps.
const tabs = [_]Tab{
    .{ .filter = .all, .label = "All", .left = 128, .right = 214 },
    .{ .filter = .unread, .label = "Unread", .left = 214, .right = 370 },
    .{ .filter = .read, .label = "Read", .left = 370, .right = 490 },
};
const tab_pad = 14; // From a tab's left edge to its label

// Filter and sort buttons: rounded outlines across the middle of the tabs row
const button_top = 10;
const button_height = 66;

const footer = draw.Pager{ .top = 1530, .bottom = 1650 }; // Near the bottom edge, clear of the grid
const sort_left = 860;

pub const Hit = union(enum) { none, hero, hero_dots, book: usize, dots: usize, prev, next, sort, menu, search, clear_search, tab: catalog.Filter };

// The round search button, just right of the filter button
const search_cx = 552;
const search_reach = 44; // Taps this far either side of its centre

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

/// What a tap on this library page lands on. While `searching`, the hero's place
/// holds the search, and tapping it clears the search.
pub fn hit(x: i32, y: i32, page: usize, books: usize, searching: bool) Hit {
    const hero = page == 0;
    if (y < status_height) return if (x < 220) .menu else .none;
    if (hero and y >= hero_top and y < hero_bottom) {
        if (searching) return .clear_search;
        if (x >= 1100 and y < hero_top + 90) return .hero_dots;
        return .hero;
    }

    const tabs_top = tabsTop(hero);
    if (y >= tabs_top and y < tabs_top + tabs_height) {
        if (x >= sort_left) return .sort;
        if (@abs(x - search_cx) <= search_reach) return .search;
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
            try draw.clipped(font, page, x, row, rest, avail);
            return line + 1;
        }
        const n = try lineBreak(font, rest, avail);
        try font.draw(page, x, row, rest[0..n]);
        rest = std.mem.trimStart(u8, rest[n..], " ");
    }
    return line;
}

/// A thin gray track with a thick rounded black fill. Any progress at all shows as
/// at least a dot.
fn progressBar(page: Page, x: u32, y: u32, w: u32, percent: u32, thick: f32) void {
    const left: f32 = @floatFromInt(x);
    const cy: f32 = @floatFromInt(y);
    const r = thick / 2;
    page.pill(left + r, left + @as(f32, @floatFromInt(w)) - r, cy, r / 2, 0xb8);
    if (percent == 0) return;
    const filled = @as(f32, @floatFromInt(w)) * @as(f32, @floatFromInt(@min(percent, 100))) / 100;
    page.pill(left + r, left + @max(filled - r, r), cy, r, 0x00);
}

/// "32%" in a small white pill over a cover's bottom left corner.
fn percentBadge(font: *Font, page: Page, x: u32, y: u32, percent: u32) !void {
    var label: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&label, "{d}%", .{@min(percent, 100)}) catch return;
    const r: f32 = 19;
    const left: f32 = @floatFromInt(x + 12);
    const cy: f32 = @as(f32, @floatFromInt(y)) - 12 - r;
    const w = try font.measure(s) + 26;
    const ends = [2]f32{ left + r, left + @max(w - r, r) };
    page.pill(ends[0], ends[1], cy, r, 0x00);
    page.pill(ends[0], ends[1], cy, r - 2, 0xff);
    try font.draw(page, left + 13, @intFromFloat(cy + 9), s);
}

/// A rounded outline around a control, so it reads as something to press.
fn buttonOutline(page: Page, left: f32, right: f32, top: i32) void {
    const r: f32 = button_height / 2;
    const cy: f32 = @floatFromInt(top + button_top + button_height / 2);
    page.pill(left + r, right - r, cy, r, 0x00);
    page.pill(left + r, right - r, cy, r - 2, 0xff);
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
    try draw.clipped(fonts.caption, page, left, @intCast(y + h - 34), e.author, avail);
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
    try draw.clipped(fonts.small, page, left, author_y, e.author, avail);
    page.tint(left_px, @intCast(author_y - 30), @intFromFloat(avail), 44, 0x50);

    const bar_y = hero_top + cover.hero_height - 40;
    progressBar(page, left_px, bar_y, @intFromFloat(avail), e.percent, 12);
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
    if (e.inProgress()) {
        progressBar(page, x, bar_y + 2, cover.width, e.percent, 10);
        try percentBadge(fonts.caption, page, x, y + cover.height, e.percent);
    }
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

/// In the hero's place while searching: what was searched for, how many books have
/// it, and a button to clear it.
fn drawSearchHeader(fonts: Fonts, page: Page, query: []const u8, found: usize) !void {
    const left: f32 = margin;
    const avail: f32 = @floatFromInt(page.width - 2 * margin);
    try fonts.caption.draw(page, left, hero_top + 34, "Search results");
    page.tint(margin, hero_top + 8, @intFromFloat(avail), 36, 0x60);
    var quoted: [80]u8 = undefined;
    const shown = std.fmt.bufPrint(&quoted, "\u{201c}{s}\u{201d}", .{query}) catch query;
    try draw.clipped(fonts.hero, page, left, hero_top + 120, shown, avail);
    var count: [32]u8 = undefined;
    const books = std.fmt.bufPrint(&count, "{d} book{s}", .{ found, if (found == 1) "" else "s" }) catch "";
    try fonts.small.draw(page, left, hero_top + 190, books);
    const label = "Clear search";
    const w = try fonts.small.measure(label);
    const top: i32 = hero_top + 236 - button_top;
    buttonOutline(page, left, left + w + 60, top);
    try fonts.small.draw(page, left + 30, top + 55, label);
}

fn drawTabs(fonts: Fonts, page: Page, top: i32, filter: catalog.Filter, order: catalog.Order, searching: bool) !void {
    const y = top + 55;
    const cy: f32 = @floatFromInt(top + button_top + button_height / 2);
    const r: f32 = button_height / 2;
    page.pill(search_cx, search_cx, cy, r, 0x00);
    page.pill(search_cx, search_cx, cy, r - 2, 0xff);
    icons.search(page, search_cx, cy);
    // Filled while a search is showing, like a toggle that's on
    if (searching) page.invertDisc(search_cx, @intFromFloat(cy), @intFromFloat(r - 2));
    buttonOutline(page, margin, @floatFromInt(tabs[tabs.len - 1].right), top);
    icons.funnel(page, margin + 34, cy);
    for (tabs) |t| {
        const left: u32 = @intCast(t.left + tab_pad);
        const active = t.filter == filter;
        try draw.choice(fonts, page, @floatFromInt(left), .left, y, t.label, active, @intCast(top + 63));
        if (!active) page.tint(left, @intCast(top + 22), @intCast(t.right - t.left - tab_pad - 4), 44, style.faded);
    }
    const right: f32 = @floatFromInt(page.width - margin);
    const sort_w = try fonts.small.measure(order.label());
    const button_left = right - 28 - sort_w - 14 - 30 - 22;
    buttonOutline(page, button_left, right, top);
    icons.sortArrows(page, button_left + 22 + 15, cy);
    try fonts.small.draw(page, right - 28 - sort_w, y, order.label());
}

fn drawFooter(fonts: Fonts, page: Page, index: usize, pages: usize) !void {
    try footer.render(fonts, page, index, pages);
}

pub fn render(alloc: std.mem.Allocator, fonts: Fonts, page: Page, entries: []catalog.Entry, hero: ?usize, visible: []const usize, index: usize, filter: catalog.Filter, order: catalog.Order, query: []const u8, message: []const u8, quick: *const quick_model.Quick) !void {
    @memset(page.buf, 0xff);
    try drawStatus(fonts, page, quick);

    const with_hero = index == 0;
    if (with_hero) {
        if (query.len > 0) {
            try drawSearchHeader(fonts, page, query, visible.len);
        } else if (hero) |h| try drawHero(alloc, fonts, page, &entries[h]);
    }
    try drawTabs(fonts, page, tabsTop(with_hero), filter, order, query.len > 0);

    const first = firstBook(index);
    const shown = visible[@min(first, visible.len)..@min(first + gridSize(with_hero), visible.len)];
    const top: u32 = @intCast(gridTop(with_hero));
    for (shown, 0..) |entry_index, i| {
        const x: u32 = margin + @as(u32, @intCast(i % columns)) * cell_step;
        const y: u32 = top + @as(u32, @intCast(i / columns)) * row_height;
        try drawCell(alloc, fonts, page, &entries[entry_index], x, y);
    }
    if (visible.len == 0) try fonts.small.draw(page, margin, @intCast(top + 60), if (query.len > 0) "No books match." else "No books here yet.");
    try drawFooter(fonts, page, index, pageCount(visible.len));
    if (message.len > 0) try fonts.caption.draw(page, margin, 1500, message); // Between grid and pager
}

test "the current book stays on page one of every view" {
    try std.testing.expectEqual(Hit.hero, hit(300, 200, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(100, 700, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 3 }, hit(1000, 700, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 4 }, hit(100, 1100, 0, 79, false));
}

test "later pages are four by three" {
    try std.testing.expectEqual(Hit{ .book = 8 }, hit(100, 300, 1, 79, false));
    try std.testing.expectEqual(Hit{ .book = 19 }, hit(1000, 1100, 1, 79, false));
}

test "header and footer controls" {
    try std.testing.expectEqual(Hit.menu, hit(100, 50, 0, 79, false));
    try std.testing.expectEqual(Hit{ .tab = .unread }, hit(250, 560, 0, 79, false));
    try std.testing.expectEqual(Hit{ .tab = .read }, hit(400, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.none, hit(600, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.sort, hit(1100, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.prev, hit(400, 1600, 0, 79, false));
    try std.testing.expectEqual(Hit.next, hit(800, 1600, 0, 79, false));
}

test "tapping past the last book does nothing" {
    try std.testing.expectEqual(Hit.none, hit(1000, 1100, 0, 3, false));
}

test "page count follows the layout" {
    try std.testing.expectEqual(@as(usize, 1), pageCount(0));
    try std.testing.expectEqual(@as(usize, 1), pageCount(8));
    try std.testing.expectEqual(@as(usize, 2), pageCount(9));
    try std.testing.expectEqual(@as(usize, 7), pageCount(78));
}

test "search button sits beside the filter, and the search takes the hero's place" {
    try std.testing.expectEqual(Hit.search, hit(552, 560, 0, 79, false));
    try std.testing.expectEqual(Hit{ .tab = .read }, hit(480, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.search, hit(552, 140, 1, 79, false));
    try std.testing.expectEqual(Hit.clear_search, hit(300, 300, 0, 79, true));
    try std.testing.expectEqual(Hit.hero, hit(300, 300, 0, 79, false));
}

test "three dots sit beside the title" {
    try std.testing.expectEqual(Hit{ .dots = 0 }, hit(300, 975, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(120, 975, 0, 79, false));
    try std.testing.expectEqual(Hit.hero_dots, hit(1180, 130, 0, 79, false));
}
