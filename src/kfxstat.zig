//! Parses a KFX file and prints counts only, never book text.
const std = @import("std");
const linux = std.os.linux;
const file = @import("file.zig");
const kfx = @import("kfx.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 2) return error.Usage;
    const data = try file.map(argv[1]);

    var ts0: linux.timespec = undefined;
    var ts1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts0);
    const book = try kfx.parse(std.heap.page_allocator, data);
    _ = linux.clock_gettime(.MONOTONIC, &ts1);

    var bytes: usize = 0;
    var non_ascii: usize = 0;
    var longest: usize = 0;
    var valid: usize = 0;
    var links: usize = 0;
    var notes: usize = 0;
    var note_bytes: usize = 0;
    for (book.paragraphs) |p| {
        bytes += p.text.len;
        links += p.links.len;
        if (p.note) {
            notes += 1;
            note_bytes += p.text.len;
        }
        longest = @max(longest, p.text.len);
        if (std.unicode.utf8ValidateSlice(p.text)) valid += 1;
        for (p.text) |c| {
            if (c >= 0x80) non_ascii += 1;
        }
    }
    // Are references number-like marks, or words that shouldn't be references?
    var refs_mark: usize = 0;
    var refs_word: usize = 0;
    var starts: usize = 0;
    var multi: usize = 0;
    var capped: usize = 0;
    var longest_note: usize = 0;
    var first_refs: [3]usize = undefined;
    var first_refs_len: usize = 0;
    for (book.paragraphs, 0..) |p, i| {
        for (p.links) |l| {
            if (l.target >= book.paragraphs.len or !book.paragraphs[l.target].note_start) continue;
            if (kfx.isMark(p.text[l.start..l.end])) refs_mark += 1 else refs_word += 1;
            if (first_refs_len < first_refs.len) {
                first_refs[first_refs_len] = i;
                first_refs_len += 1;
            }
        }
        if (!p.note_start) continue;
        starts += 1;
        const parts = kfx.noteLength(book.paragraphs, i);
        if (parts > 1) multi += 1;
        if (parts == kfx.max_note_parts) capped += 1;
        var size: usize = 0;
        for (book.paragraphs[i..][0..parts]) |part| size += part.text.len;
        longest_note = @max(longest_note, size);
    }
    std.debug.print("refs mark {d} word {d}, notes {d}, multi {d}, capped {d}, longest {d}\n", .{ refs_mark, refs_word, starts, multi, capped, longest_note });
    std.debug.print("first refs {any}\n", .{first_refs[0..first_refs_len]});

    const us = (ts1.sec - ts0.sec) * 1_000_000 + @divTrunc(ts1.nsec - ts0.nsec, 1000);
    std.debug.print(
        "sections {d}, paragraphs {d}, text bytes {d}, non-ascii bytes {d}, valid utf8 {d}, longest {d}, missing refs {d}, links {d}, notes {d}, note bytes {d}, parse {d} us\n",
        .{ book.sections, book.paragraphs.len, bytes, non_ascii, valid, longest, book.missing_refs, links, notes, note_bytes, us },
    );
}
