//! Highlights in a book: where they sit in the text, and how they map to a page.
const std = @import("std");
const kfx = @import("kfx.zig");
const text = @import("text.zig");

/// A highlight, plus the Amazon ID that keeps edits on the same record.
pub const Highlight = struct { mark: text.Mark, id: []const u8 };

/// Finds the paragraph and byte for one of Amazon's short positions.
pub fn locate(paragraphs: []const kfx.Paragraph, short: u32) ?struct { para: u32, byte: u32 } {
    var found: ?usize = null;
    for (paragraphs, 0..) |p, i| {
        if (p.position == 0) continue;
        if (p.position <= short) found = i else break;
    }
    const i = found orelse return null;
    const p = paragraphs[i];
    return .{ .para = @intCast(i), .byte = @intCast(kfx.byteOffset(p.text, short - p.position)) };
}

/// Reads "id|start|end" lines from the annotation database.
pub fn parse(alloc: std.mem.Allocator, paragraphs: []const kfx.Paragraph, lines: []const u8) ![]Highlight {
    var out: std.ArrayList(Highlight) = .empty;
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        const id = fields.next() orelse continue;
        const start = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const end = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const from = locate(paragraphs, start) orelse continue;
        const to = locate(paragraphs, end) orelse continue;
        if (from.para != to.para) {
            // One mark per paragraph, so every paragraph it crosses is drawn.
            var para = from.para;
            while (para <= to.para) : (para += 1) {
                const first = if (para == from.para) from.byte else 0;
                const last: u32 = if (para == to.para) to.byte else @intCast(paragraphs[para].text.len);
                try out.append(alloc, .{ .mark = .{ .para = para, .start = first, .end = last }, .id = try alloc.dupe(u8, id) });
            }
            continue;
        }
        try out.append(alloc, .{ .mark = .{ .para = from.para, .start = from.byte, .end = to.byte }, .id = try alloc.dupe(u8, id) });
    }
    return out.toOwnedSlice(alloc);
}

fn overlaps(m: text.Mark, w: text.Word) bool {
    return w.para == m.para and w.start < m.end and w.end > m.start;
}

/// Adds a highlight from one word to another, one mark per paragraph it crosses.
pub fn add(list: *std.ArrayList(Highlight), alloc: std.mem.Allocator, paragraphs: []const kfx.Paragraph, id: []const u8, lo: text.Word, hi: text.Word) !void {
    var index = lo.para;
    while (index <= hi.para) : (index += 1) {
        const first = if (index == lo.para) lo.start else 0;
        const last: u32 = if (index == hi.para) hi.end else @intCast(paragraphs[index].text.len);
        try list.append(alloc, .{ .mark = .{ .para = index, .start = first, .end = last }, .id = id });
    }
}

/// Removes every mark of a highlight.
pub fn remove(list: *std.ArrayList(Highlight), id: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].id, id)) {
            _ = list.orderedRemove(i);
        } else i += 1;
    }
}

/// First and last word of a highlight on this page.
pub fn wordRange(words: []const text.Word, list: []const Highlight, id: []const u8) ?struct { lo: usize, hi: usize } {
    var lo: ?usize = null;
    var hi: usize = 0;
    for (words, 0..) |w, i| {
        for (list) |h| {
            if (!std.mem.eql(u8, h.id, id) or !overlaps(h.mark, w)) continue;
            if (lo == null) lo = i;
            hi = i;
            break;
        }
    }
    return if (lo) |l| .{ .lo = l, .hi = hi } else null;
}

/// The ID of the highlight containing a word, if any.
pub fn atWord(list: []const Highlight, w: text.Word) ?[]const u8 {
    for (list) |h| {
        if (overlaps(h.mark, w)) return h.id;
    }
    return null;
}

fn sample(content: []const u8, position: u32) kfx.Paragraph {
    return .{ .text = content, .style = 0, .position = position };
}

test "short positions find paragraph and byte" {
    const paras = [_]kfx.Paragraph{ sample("abcdef", 100), sample("\u{e1}bcd", 106) };
    const a = locate(&paras, 102).?;
    try std.testing.expectEqual(@as(u32, 0), a.para);
    try std.testing.expectEqual(@as(u32, 2), a.byte);
    const b = locate(&paras, 107).?;
    try std.testing.expectEqual(@as(u32, 1), b.para);
    try std.testing.expectEqual(@as(u32, 2), b.byte); // The accent takes two bytes
    try std.testing.expect(locate(&paras, 50) == null);
}

test "database lines become marks, split across paragraphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]kfx.Paragraph{ sample("abcdef", 100), sample("ghijkl", 106) };
    const list = try parse(arena.allocator(), &paras, "kindle.highlight-101|101|104\nkindle.highlight-104|104|108\nbad line\n");
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(u32, 1), list[0].mark.start);
    try std.testing.expectEqual(@as(u32, 4), list[0].mark.end);
    try std.testing.expectEqual(@as(u32, 1), list[2].mark.para);
    try std.testing.expectEqual(@as(u32, 2), list[2].mark.end);
}

test "words map to a highlight" {
    const words = [_]text.Word{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .para = 0, .start = 0, .end = 3 },
        .{ .x = 20, .y = 0, .w = 10, .h = 10, .para = 0, .start = 4, .end = 7 },
        .{ .x = 40, .y = 0, .w = 10, .h = 10, .para = 0, .start = 8, .end = 11 },
    };
    const list = [_]Highlight{.{ .mark = .{ .para = 0, .start = 4, .end = 11 }, .id = "x" }};
    const r = wordRange(&words, &list, "x").?;
    try std.testing.expectEqual(@as(usize, 1), r.lo);
    try std.testing.expectEqual(@as(usize, 2), r.hi);
    try std.testing.expect(wordRange(&words, &list, "y") == null);
    try std.testing.expectEqualStrings("x", atWord(&list, words[1]).?);
    try std.testing.expect(atWord(&list, words[0]) == null);
}

test "a highlight crossing paragraphs covers both and stays one highlight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const paras = [_]kfx.Paragraph{ sample("first para text here", 100), sample("second para", 121) };
    const words = [_]text.Word{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .para = 0, .start = 11, .end = 15 },
        .{ .x = 0, .y = 20, .w = 10, .h = 10, .para = 0, .start = 16, .end = 20 },
        .{ .x = 0, .y = 40, .w = 10, .h = 10, .para = 1, .start = 0, .end = 6 },
    };
    var list: std.ArrayList(Highlight) = .empty;
    try add(&list, alloc, &paras, "h", words[0], words[2]);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u32, 20), list.items[0].mark.end);
    try std.testing.expectEqual(@as(u32, 0), list.items[1].mark.start);
    const r = wordRange(&words, list.items, "h").?;
    try std.testing.expectEqual(@as(usize, 0), r.lo);
    try std.testing.expectEqual(@as(usize, 2), r.hi);
    remove(&list, "h");
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
