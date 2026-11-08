//! The Go To sheet: the book's contents, a page of entries at a time, under the toolbar.
const std = @import("std");
const draw = @import("draw.zig");
const library = @import("library.zig");
const style = @import("style.zig");
const kfx = @import("../book/kfx.zig");
const text = @import("../book/text.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const top = 228; // Under the toolbar, which stays visible above
const heading_baseline = top + 72;
const list_top = top + 112;
const row_height = 100;
pub const rows = 11;
const indent = 48; // Per level of nesting
const page_label_width = 140;
const pager = draw.Pager{ .top = list_top + rows * row_height + 20, .bottom = list_top + rows * row_height + 140 };

pub fn pageCount(chapters: usize) usize {
    return @max(1, (chapters + rows - 1) / rows);
}

/// The list page holding a chapter, so the sheet opens where the reader is.
pub fn listPageOf(chapter: usize) usize {
    return chapter / rows;
}

/// The chapter being read: the last one starting at or before `para`.
pub fn current(chapters: []const kfx.Chapter, para: usize) ?usize {
    var found: ?usize = null;
    var best: u32 = 0;
    for (chapters, 0..) |c, i| {
        if (c.para <= para and (found == null or c.para >= best)) {
            found = i;
            best = c.para;
        }
    }
    return found;
}

pub const Hit = union(enum) { none, close, chapter: usize, prev, next };

pub fn hit(x: i32, y: i32, list_page: usize, chapters: usize) Hit {
    if (y < top) return .close;
    if (pager.hit(x, y)) |h| return if (h == .prev) .prev else .next;
    if (y < list_top) return .none;
    const row: usize = @intCast(@divTrunc(y - list_top, row_height));
    if (row >= rows) return .none;
    const index = list_page * rows + row;
    return if (index < chapters) .{ .chapter = index } else .none;
}

/// Draws one page of the list. `page_of` holds each chapter's page number.
pub fn render(fonts: Fonts, page: text.Page, chapters: []const kfx.Chapter, page_of: []const usize, reading: ?usize, list_page: usize) !void {
    page.fillRect(0, top, page.width, page.height - top, style.white);
    page.fillRect(0, top, page.width, 1, style.rule);
    try fonts.title.draw(page, style.margin, heading_baseline, "Contents");
    page.fillRect(style.margin, list_top - 12, page.width - 2 * style.margin, 1, style.rule);
    if (chapters.len == 0) {
        try draw.centered(fonts.small, page, @floatFromInt(page.width / 2), list_top + 200, "This book has no contents list.");
        return;
    }
    const first = list_page * rows;
    const end = @min(first + rows, chapters.len);
    const right: f32 = @floatFromInt(page.width - style.margin);
    for (chapters[first..end], first..) |c, i| {
        const y: u32 = list_top + @as(u32, @intCast(i - first)) * row_height;
        const baseline: i32 = @intCast(y + 62);
        const here = reading == i;
        const left: f32 = @floatFromInt(style.margin + @as(u32, @min(c.depth, 4)) * indent);
        const font = if (here) fonts.title else fonts.small;
        try library.drawClipped(font, page, left, baseline, c.title, right - page_label_width - left);
        if (here) page.fillRect(style.margin - 28, y + 22, 8, 56, style.black);
        var label: [16]u8 = undefined;
        const number = std.fmt.bufPrint(&label, "{d}", .{page_of[i] + 1}) catch "";
        try fonts.caption.draw(page, right - try fonts.caption.measure(number), baseline, number);
    }
    try pager.render(fonts, page, list_page, pageCount(chapters.len));
}

test "the current chapter is the last one started" {
    const chapters = [_]kfx.Chapter{
        .{ .title = "a", .para = 0, .depth = 0 },
        .{ .title = "b", .para = 10, .depth = 0 },
        .{ .title = "b.1", .para = 12, .depth = 1 },
        .{ .title = "c", .para = 30, .depth = 0 },
    };
    try std.testing.expectEqual(@as(usize, 0), current(&chapters, 5).?);
    try std.testing.expectEqual(@as(usize, 2), current(&chapters, 20).?);
    try std.testing.expectEqual(@as(usize, 3), current(&chapters, 99).?);
    const late = [_]kfx.Chapter{.{ .title = "x", .para = 50, .depth = 0 }};
    try std.testing.expect(current(&late, 5) == null);
}

test "rows map to chapters on the shown page" {
    try std.testing.expectEqual(Hit.close, hit(600, 100, 0, 30));
    try std.testing.expectEqual(Hit{ .chapter = 0 }, hit(600, list_top + 10, 0, 30));
    try std.testing.expectEqual(Hit{ .chapter = rows + 2 }, hit(600, list_top + 2 * row_height + 10, 1, 30));
    try std.testing.expectEqual(Hit.none, hit(600, list_top + 9 * row_height + 10, 2, 30)); // Past the last
    try std.testing.expectEqual(@as(usize, 3), pageCount(30));
    try std.testing.expectEqual(@as(usize, 1), pageCount(0));
}

test "the list fits on screen" {
    try std.testing.expect(pager.bottom <= style.screen_height);
}
