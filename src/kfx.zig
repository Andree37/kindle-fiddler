//! KFX container reader. Handles unencrypted, uncompressed books only.
const std = @import("std");
const ion = @import("ion.zig");

const f_name = 4;
const f_style_events = 142;
const f_event_offset = 143;
const f_event_length = 144;
const f_id = 155;
const f_link = 179;
const f_anchor_position = 183;
const f_section_item = 141;
const f_content_ref = 145;
const f_children = 146;
const f_style = 157;
const f_reading_orders = 169;
const f_sections = 170;
const f_story = 176;
const f_index = 403;
const f_compression = 410;
const f_drm = 411;
const f_index_offset = 413;
const f_index_length = 414;

const t_content = 145;
const t_anchor = 266;
const t_story = 259;
const t_section = 260;
const t_document = 538;
const t_book_nav = 258;

/// A byte range of a paragraph that links to another paragraph.
pub const Link = struct { start: usize, end: usize, target: u32 };

pub const Paragraph = struct {
    text: []const u8,
    style: u32,
    links: []const Link = &.{},
    section: u32 = 0,
    note: bool = false, // Part of a note, so hidden from the flow
    note_start: bool = false, // First paragraph of a note: what references point at
};

const max_reference_bytes = 12;
const max_label_bytes = 8;

const max_note_gap = 3;
pub const max_note_parts = 8;

/// Paragraphs a note spans, starting at its target.
pub fn noteLength(paragraphs: []const Paragraph, target: usize) usize {
    var n: usize = 1;
    while (n < max_note_parts and target + n < paragraphs.len) : (n += 1) {
        const p = paragraphs[target + n];
        if (!p.note or p.note_start) break;
    }
    return n;
}

fn hasNoteReference(p: Paragraph, paragraphs: []const Paragraph) bool {
    for (p.links) |l| {
        if (l.target < paragraphs.len and paragraphs[l.target].note_start) return true;
    }
    return false;
}

/// Note marks are numbers or symbols. A word in a link is an ordinary cross-reference.
pub fn isMark(s: []const u8) bool {
    var letters: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        const latin = cp >= 0xc0 and cp <= 0x24f;
        if (latin or (cp < 0x80 and std.ascii.isAlphabetic(@intCast(cp)))) letters += 1;
    }
    return letters <= 1;
}

/// A short link inside longer text pointing forward is a note reference.
/// That leaves out contents pages, where the link is the whole line, and
/// back-links inside notes, which point backward.
pub fn markNotes(paragraphs: []Paragraph) void {
    for (paragraphs, 0..) |p, i| {
        for (p.links) |l| {
            if (l.target <= i or l.target >= paragraphs.len) continue;
            const span = l.end - l.start;
            if (span > max_reference_bytes or span * 2 > p.text.len) continue;
            if (!isMark(p.text[l.start..l.end])) continue;
            paragraphs[l.target].note = true;
            paragraphs[l.target].note_start = true;
        }
    }

    // Some books put the number in its own paragraph, with the text in the next.
    for (paragraphs, 0..) |p, i| {
        if (p.note_start and p.text.len <= max_label_bytes and i + 1 < paragraphs.len) paragraphs[i + 1].note = true;
    }

    // Short gaps between two notes of a section are the rest of the first note,
    // unless a gap paragraph itself references a note, which makes it body text.
    var previous: ?usize = null;
    for (paragraphs, 0..) |p, i| {
        if (!p.note_start) continue;
        defer previous = i;
        const from = previous orelse continue;
        if (paragraphs[from].section != p.section or i - from - 1 > max_note_gap) continue;
        const gap = paragraphs[from + 1 .. i];
        var is_body = false;
        for (gap) |g| {
            if (hasNoteReference(g, paragraphs)) is_body = true;
        }
        if (is_body) continue;
        for (gap) |*g| g.note = true;
    }
}

/// Byte offset of the `count`th code point, as KFX offsets count characters.
pub fn byteOffset(text: []const u8, count: u64) usize {
    var bytes: usize = 0;
    var seen: u64 = 0;
    while (bytes < text.len and seen < count) : (seen += 1) {
        bytes += std.unicode.utf8ByteSequenceLength(text[bytes]) catch 1;
    }
    return @min(bytes, text.len);
}

const RawLink = struct { para: u32, start: usize, end: usize, anchor: u32 };

pub const Book = struct {
    paragraphs: []Paragraph,
    sections: u32,
    missing_refs: u32,
};

const Key = struct { id: u32, kind: u32 };

const Parser = struct {
    alloc: std.mem.Allocator,
    index: std.AutoHashMapUnmanaged(Key, []const u8) = .empty,
    paragraphs: std.ArrayList(Paragraph) = .empty,
    missing: u32 = 0,
    positions: std.AutoHashMapUnmanaged(u64, u32) = .empty, // Element ID to paragraph
    raw_links: std.ArrayList(RawLink) = .empty,
    section: u32 = 0,

    fn collectLinks(p: *Parser, item: ion.Value, para: u32, text: []const u8) !void {
        const events = item.get(f_style_events) orelse return;
        var it = events.items();
        while (it.next()) |event| {
            const anchor = (event.get(f_link) orelse continue).symbol() orelse continue;
            const offset = (event.get(f_event_offset) orelse continue).unsigned() orelse continue;
            const length = (event.get(f_event_length) orelse continue).unsigned() orelse continue;
            try p.raw_links.append(p.alloc, .{
                .para = para,
                .start = byteOffset(text, offset),
                .end = byteOffset(text, offset + length),
                .anchor = anchor,
            });
        }
    }

    /// Turns anchors into paragraph indexes, now that every position is known.
    fn resolveLinks(p: *Parser) !void {
        var i: usize = 0;
        while (i < p.raw_links.items.len) {
            const para = p.raw_links.items[i].para;
            var links: std.ArrayList(Link) = .empty;
            while (i < p.raw_links.items.len and p.raw_links.items[i].para == para) : (i += 1) {
                const raw = p.raw_links.items[i];
                const anchor = p.entity(raw.anchor, t_anchor) orelse continue;
                const position = anchor.get(f_anchor_position) orelse continue;
                const id = (position.get(f_id) orelse continue).unsigned() orelse continue;
                const target = p.positions.get(id) orelse continue;
                try links.append(p.alloc, .{ .start = raw.start, .end = raw.end, .target = target });
            }
            p.paragraphs.items[para].links = try links.toOwnedSlice(p.alloc);
        }
    }

    fn entity(p: *Parser, id: u32, kind: u32) ?ion.Value {
        const raw = p.index.get(.{ .id = id, .kind = kind }) orelse return null;
        if (raw.len < 10 or !std.mem.eql(u8, raw[0..4], "ENTY")) return null;
        const hdr = std.mem.readInt(u32, raw[6..10], .little);
        if (hdr > raw.len) return null;
        return ion.parse(raw[hdr..]) catch null;
    }

    /// Resolves a text reference. False means it pointed at nothing usable.
    fn addContent(p: *Parser, ref: ion.Value, style: u32) !bool {
        if (ref.text()) |txt| {
            try p.paragraphs.append(p.alloc, .{ .text = txt, .style = style });
            return true;
        }
        const name = (ref.get(f_name) orelse return false).symbol() orelse return false;
        const wanted = (ref.get(f_index) orelse return false).unsigned() orelse return false;
        const content = p.entity(name, t_content) orelse return false;
        var strings = (content.get(f_children) orelse return false).items();
        var i: u64 = 0;
        while (strings.next()) |s| : (i += 1) {
            if (i != wanted) continue;
            const txt = s.text() orelse return false;
            try p.paragraphs.append(p.alloc, .{ .text = txt, .style = style });
            return true;
        }
        return false;
    }

    fn walk(p: *Parser, item: ion.Value, depth: u32) anyerror!void {
        if (depth > 32) return error.TooDeep;
        if (item.text()) |txt| {
            try p.paragraphs.append(p.alloc, .{ .text = txt, .style = 0 });
            return;
        }
        if (item.kind != .struct_) {
            p.missing += 1;
            return;
        }
        const style = if (item.get(f_style)) |s| s.symbol() orelse 0 else 0;
        if (item.get(f_id)) |id| {
            const slot = try p.positions.getOrPut(p.alloc, id.int);
            if (!slot.found_existing) slot.value_ptr.* = @intCast(p.paragraphs.items.len);
        }

        if (item.get(f_content_ref)) |ref| {
            if (try p.addContent(ref, style)) {
                const para: u32 = @intCast(p.paragraphs.items.len - 1);
                p.paragraphs.items[para].section = p.section;
                try p.collectLinks(item, para, p.paragraphs.items[para].text);
            } else p.missing += 1;
        }
        if (item.get(f_story)) |story| {
            // A story names itself in this same field, so only descend into its children.
            const loaded = if (story.symbol()) |id| p.entity(id, t_story) else null;
            if (loaded) |s| {
                if (s.get(f_children)) |children| {
                    var it = children.items();
                    while (it.next()) |child| try p.walk(child, depth + 1);
                }
            } else p.missing += 1;
        }
        if (item.get(f_children)) |children| {
            var it = children.items();
            while (it.next()) |child| try p.walk(child, depth + 1);
        }
    }
};

pub fn parse(alloc: std.mem.Allocator, data: []const u8) !Book {
    if (data.len < 18 or !std.mem.eql(u8, data[0..4], "CONT")) return error.NotKfx;
    const header_len = std.mem.readInt(u32, data[6..10], .little);
    const info_off = std.mem.readInt(u32, data[10..14], .little);
    const info_len = std.mem.readInt(u32, data[14..18], .little);
    if (info_off > data.len or info_len > data.len - info_off) return error.Truncated;

    const info = try ion.parse(data[info_off..][0..info_len]);
    if ((info.get(f_compression) orelse return error.BadHeader).int != 0) return error.Compressed;
    if ((info.get(f_drm) orelse return error.BadHeader).int != 0) return error.Encrypted;
    const idx_off64 = (info.get(f_index_offset) orelse return error.BadHeader).int;
    const idx_len64 = (info.get(f_index_length) orelse return error.BadHeader).int;
    if (idx_off64 > data.len or idx_len64 > data.len - idx_off64) return error.Truncated;
    if (header_len > data.len) return error.Truncated;
    const idx_off: usize = @intCast(idx_off64);
    const idx_len: usize = @intCast(idx_len64);
    const body_len = data.len - header_len;

    var p = Parser{ .alloc = alloc };
    var e: usize = 0;
    while (e + 24 <= idx_len) : (e += 24) {
        const row = data[idx_off + e..][0..24];
        const id = std.mem.readInt(u32, row[0..4], .little);
        const kind = std.mem.readInt(u32, row[4..8], .little);
        const off64 = std.mem.readInt(u64, row[8..16], .little);
        const len64 = std.mem.readInt(u64, row[16..24], .little);
        if (off64 > body_len or len64 > body_len - off64) return error.Truncated;
        const off: usize = @intCast(off64);
        try p.index.put(alloc, .{ .id = id, .kind = kind }, data[header_len + off..][0..@intCast(len64)]);
    }

    const doc = findDocument(&p) orelse return error.NoReadingOrder;
    var orders = (doc.get(f_reading_orders) orelse return error.NoReadingOrder).items();
    const order = orders.next() orelse return error.NoReadingOrder;
    var sections = (order.get(f_sections) orelse return error.NoReadingOrder).items();

    var count: u32 = 0;
    while (sections.next()) |s| {
        const section = p.entity(s.symbol() orelse continue, t_section) orelse {
            p.missing += 1;
            continue;
        };
        count += 1;
        p.section = count;
        var templates = (section.get(f_section_item) orelse continue).items();
        // Later templates are conditional alternatives of the first.
        if (templates.next()) |first| try p.walk(first, 0);
    }
    try p.resolveLinks();
    markNotes(p.paragraphs.items);
    return .{ .paragraphs = try p.paragraphs.toOwnedSlice(alloc), .sections = count, .missing_refs = p.missing };
}

fn findDocument(p: *Parser) ?ion.Value {
    var it = p.index.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.kind != t_document and kv.key_ptr.kind != t_book_nav) continue;
        if (p.entity(kv.key_ptr.id, kv.key_ptr.kind)) |v| {
            if (v.get(f_reading_orders) != null) return v;
        }
    }
    return null;
}

test "offsets that would wrap are rejected" {
    var d = std.mem.zeroes([18]u8);
    @memcpy(d[0..4], "CONT");
    std.mem.writeInt(u32, d[10..14], 0xFFFFFFF0, .little);
    std.mem.writeInt(u32, d[14..18], 0x20, .little);
    try std.testing.expectError(error.Truncated, parse(std.testing.allocator, &d));
}

test "offsets count characters, not bytes" {
    try std.testing.expectEqual(@as(usize, 3), byteOffset("\u{e1}bc", 2));
    try std.testing.expectEqual(@as(usize, 4), byteOffset("\u{e1}bc", 99));
}

test "short forward references mark their target as a note" {
    var paras = [_]Paragraph{
        .{ .text = "body text with a reference in it", .style = 0, .links = &.{.{ .start = 10, .end = 11, .target = 2 }} },
        .{ .text = "more body", .style = 0 },
        .{ .text = "the note", .style = 0, .links = &.{.{ .start = 0, .end = 1, .target = 0 }} },
    };
    markNotes(&paras);
    try std.testing.expect(paras[2].note);
    try std.testing.expect(!paras[0].note); // Back-link from the note
    try std.testing.expect(!paras[1].note);
}

test "a contents line does not hide its chapter" {
    var paras = [_]Paragraph{
        .{ .text = "Chapter 1", .style = 0, .links = &.{.{ .start = 0, .end = 9, .target = 1 }} },
        .{ .text = "Chapter 1 begins", .style = 0 },
    };
    markNotes(&paras);
    try std.testing.expect(!paras[1].note);
}

test "a number on its own takes the next paragraph with it" {
    var paras = [_]Paragraph{
        .{ .text = "body text with a reference in it", .style = 0, .links = &.{.{ .start = 10, .end = 11, .target = 1 }} },
        .{ .text = "12", .style = 0 },
        .{ .text = "the note text itself, which is much longer", .style = 0 },
        .{ .text = "body continues here", .style = 0 },
    };
    markNotes(&paras);
    try std.testing.expect(paras[1].note);
    try std.testing.expect(paras[2].note);
    try std.testing.expect(!paras[3].note);
}

test "paragraphs between notes stay with their note" {
    var paras = [_]Paragraph{
        .{ .text = "body text with a reference and another one", .style = 0, .links = &.{ .{ .start = 5, .end = 6, .target = 1 }, .{ .start = 9, .end = 10, .target = 3 } } },
        .{ .text = "first note", .style = 0, .section = 1 },
        .{ .text = "second paragraph of the first note", .style = 0, .section = 1 },
        .{ .text = "second note", .style = 0, .section = 1 },
        .{ .text = "next chapter", .style = 0, .section = 2 },
    };
    markNotes(&paras);
    try std.testing.expect(paras[2].note);
    try std.testing.expectEqual(@as(usize, 2), noteLength(&paras, 1));
    try std.testing.expectEqual(@as(usize, 1), noteLength(&paras, 3));
    try std.testing.expect(!paras[4].note);
}

test "inline notes do not swallow body text with references" {
    var paras = [_]Paragraph{
        .{ .text = "body text with a reference in it", .style = 0, .links = &.{.{ .start = 5, .end = 6, .target = 1 }} },
        .{ .text = "inline note", .style = 0 },
        .{ .text = "more body text with its own reference", .style = 0, .links = &.{.{ .start = 5, .end = 6, .target = 3 }} },
        .{ .text = "another inline note", .style = 0 },
    };
    markNotes(&paras);
    try std.testing.expect(!paras[2].note);
}

test "marks are numbers and symbols, not words" {
    try std.testing.expect(isMark("12"));
    try std.testing.expect(isMark("[3]"));
    try std.testing.expect(isMark("*"));
    try std.testing.expect(isMark("\u{2020}"));
    try std.testing.expect(isMark("a"));
    try std.testing.expect(!isMark("Taleb"));
    try std.testing.expect(!isMark("\u{e9}t\u{e9}"));
}

test "a linked word does not hide its target" {
    var paras = [_]Paragraph{
        .{ .text = "as argued by Popper in the earlier chapter", .style = 0, .links = &.{.{ .start = 13, .end = 19, .target = 1 }} },
        .{ .text = "a heading that must stay visible", .style = 0 },
    };
    markNotes(&paras);
    try std.testing.expect(!paras[1].note);
}
