//! Book list, read from the tab-separated file start.sh exports from the
//! Kindle's own database: path, title, author, percent, last opened.
const std = @import("std");
const text = @import("text.zig");

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
};

/// Converted filenames look like "Title -- Author -- Year -- junk".
pub fn cleanTitle(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " -- ") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
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
        if (path.len == 0) continue;
        try out.append(alloc, .{
            .path = try alloc.dupeSentinel(u8, path, 0),
            .title = cleanTitle(title),
            .author = cleanAuthor(author),
            .percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .last = last,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn newerFirst(_: void, a: Entry, b: Entry) bool {
    return a.last > b.last;
}

pub fn sort(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, newerFirst);
}

pub const rows_per_page = 9;
const margin = 80;
const top = 150;
const row_height = 140;
const buttons_top = 1420;
const buttons_bottom = 1560;
const prev_left = 320;
const next_left = 652;
const button_width = 300;
const exit_width = 300;

pub const Fonts = struct { title: *text.Font, small: *text.Font };

pub const Hit = union(enum) { none, book: usize, prev, next, exit };

pub fn pageCount(entries: usize) usize {
    return @max((entries + rows_per_page - 1) / rows_per_page, 1);
}

/// What a tap on this library page lands on.
pub fn hit(x: i32, y: i32, width: i32, page: usize, entries: usize) Hit {
    if (y < top) return if (x >= width - exit_width) .exit else .none;
    if (y >= buttons_top and y < buttons_bottom) {
        if (x >= prev_left and x < prev_left + button_width) return .prev;
        if (x >= next_left and x < next_left + button_width) return .next;
        return .none;
    }
    if (y >= top + rows_per_page * row_height) return .none;
    const row: usize = @intCast(@divTrunc(y - top, row_height));
    const index = page * rows_per_page + row;
    return if (index < entries) .{ .book = index } else .none;
}

fn drawClipped(font: *text.Font, page: text.Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
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

pub fn render(fonts: Fonts, page: text.Page, entries: []const Entry, index: usize, message: []const u8) !void {
    @memset(page.buf, 0xff);
    const right: f32 = @floatFromInt(page.width - margin);
    try fonts.title.draw(page, margin, 100, "Library");
    try fonts.small.draw(page, right - 150, 100, "Kindle");
    page.fillRect(margin, top - 12, page.width - 2 * margin, 3, 0x00);

    const first = index * rows_per_page;
    const shown = entries[@min(first, entries.len)..@min(first + rows_per_page, entries.len)];
    for (shown, 0..) |e, i| {
        const y: i32 = top + @as(i32, @intCast(i)) * row_height;
        const avail: f32 = right - margin - 120;
        try drawClipped(fonts.title, page, margin, y + 58, e.title, avail);
        try drawClipped(fonts.small, page, margin, y + 104, e.author, avail);

        var label: [8]u8 = undefined;
        const pct = std.fmt.bufPrint(&label, "{d}%", .{e.percent}) catch "";
        try fonts.small.draw(page, right - 90, y + 58, pct);

        const bar_y: u32 = @intCast(y + 124);
        const bar_w = page.width - 2 * margin;
        page.fillRect(margin, bar_y, bar_w, 2, 0xc0);
        page.fillRect(margin, bar_y, bar_w * e.percent / 100, 6, 0x00);
    }

    try fonts.title.draw(page, prev_left + 50, buttons_top + 90, "Previous");
    try fonts.title.draw(page, next_left + 100, buttons_top + 90, "Next");

    var label: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, pageCount(entries.len) }) catch "";
    try fonts.small.draw(page, @as(f32, @floatFromInt(page.width)) / 2 - 40, 1620, count);
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
    sort(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("New", rows[0].title);
    try std.testing.expectEqual(@as(u32, 12), rows[1].percent);
    try std.testing.expectEqualStrings("Old", rows[1].title);
}

test "taps map to rows, buttons and exit" {
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(300, 200, 1272, 0, 79));
    try std.testing.expectEqual(Hit{ .book = 10 }, hit(300, 320, 1272, 1, 79));
    try std.testing.expectEqual(Hit.prev, hit(400, 1500, 1272, 0, 79));
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
