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

/// First and last word of a highlight on this page.
pub fn wordRange(words: []const text.Word, m: text.Mark) ?struct { lo: usize, hi: usize } {
    var lo: ?usize = null;
    var hi: usize = 0;
    for (words, 0..) |w, i| {
        if (!overlaps(m, w)) continue;
        if (lo == null) lo = i;
        hi = i;
    }
    return if (lo) |l| .{ .lo = l, .hi = hi } else null;
}

/// The highlight containing a word, if any.
pub fn atWord(list: []const Highlight, w: text.Word) ?usize {
    for (list, 0..) |h, i| {
        if (overlaps(h.mark, w)) return i;
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
    const r = wordRange(&words, .{ .para = 0, .start = 4, .end = 11 }).?;
    try std.testing.expectEqual(@as(usize, 1), r.lo);
    try std.testing.expectEqual(@as(usize, 2), r.hi);
    try std.testing.expect(wordRange(&words, .{ .para = 1, .start = 0, .end = 3 }) == null);
    const list = [_]Highlight{.{ .mark = .{ .para = 0, .start = 4, .end = 7 }, .id = "x" }};
    try std.testing.expectEqual(@as(usize, 0), atWord(&list, words[1]).?);
    try std.testing.expect(atWord(&list, words[0]) == null);
}
