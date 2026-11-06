//! KFX container reader. Handles unencrypted, uncompressed books only.
const std = @import("std");
const ion = @import("ion.zig");

const f_name = 4;
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
const t_story = 259;
const t_section = 260;
const t_document = 538;
const t_book_nav = 258;

pub const Paragraph = struct { text: []const u8, style: u32 };

pub const Book = struct {
    paragraphs: []Paragraph,
    sections: u32,
    missing_refs: u32,
};

const Key = struct { id: u32, kind: u32 };

const Parser = struct {
    alloc: std.mem.Allocator,
    data: []const u8,
    header_len: usize,
    index: std.AutoHashMapUnmanaged(Key, []const u8) = .empty,
    paragraphs: std.ArrayList(Paragraph) = .empty,
    missing: u32 = 0,

    fn entity(p: *Parser, id: u32, kind: u32) ?ion.Value {
        const raw = p.index.get(.{ .id = id, .kind = kind }) orelse return null;
        if (raw.len < 10 or !std.mem.eql(u8, raw[0..4], "ENTY")) return null;
        const hdr = std.mem.readInt(u32, raw[6..10], .little);
        if (hdr > raw.len) return null;
        return ion.parse(raw[hdr..]) catch null;
    }

    fn walk(p: *Parser, item: ion.Value, depth: u32) anyerror!void {
        if (depth > 32) return error.TooDeep;
        const style = if (item.get(f_style)) |s| s.symbol() orelse 0 else 0;

        if (item.get(f_content_ref)) |ref| {
            const name = ref.get(f_name) orelse return;
            const wanted = (ref.get(f_index) orelse return).unsigned() orelse return;
            const content = p.entity(name.symbol() orelse return, t_content) orelse {
                p.missing += 1;
                return;
            };
            var strings = (content.get(f_children) orelse return).items();
            var i: u64 = 0;
            while (strings.next()) |s| : (i += 1) {
                if (i == wanted) {
                    if (s.text()) |txt| try p.paragraphs.append(p.alloc, .{ .text = txt, .style = style });
                    break;
                }
            }
        }
        if (item.get(f_story)) |story| {
            // A story names itself in this same field, so only descend into its children.
            if (p.entity(story.symbol() orelse return, t_story)) |s| {
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
    if (info_off + info_len > data.len) return error.Truncated;

    const info = try ion.parse(data[info_off..][0..info_len]);
    if ((info.get(f_compression) orelse return error.BadHeader).int != 0) return error.Compressed;
    if ((info.get(f_drm) orelse return error.BadHeader).int != 0) return error.Encrypted;
    const idx_off: usize = @intCast((info.get(f_index_offset) orelse return error.BadHeader).int);
    const idx_len: usize = @intCast((info.get(f_index_length) orelse return error.BadHeader).int);
    if (idx_off + idx_len > data.len) return error.Truncated;

    var p = Parser{ .alloc = alloc, .data = data, .header_len = header_len };
    var e: usize = 0;
    while (e + 24 <= idx_len) : (e += 24) {
        const row = data[idx_off + e..][0..24];
        const id = std.mem.readInt(u32, row[0..4], .little);
        const kind = std.mem.readInt(u32, row[4..8], .little);
        const off: usize = @intCast(std.mem.readInt(u64, row[8..16], .little));
        const len: usize = @intCast(std.mem.readInt(u64, row[16..24], .little));
        if (header_len + off + len > data.len) return error.Truncated;
        try p.index.put(alloc, .{ .id = id, .kind = kind }, data[header_len + off..][0..len]);
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
        var templates = (section.get(f_section_item) orelse continue).items();
        // Later templates are conditional alternatives of the first.
        if (templates.next()) |first| try p.walk(first, 0);
    }
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
