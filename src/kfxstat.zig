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
    const us = (ts1.sec - ts0.sec) * 1_000_000 + @divTrunc(ts1.nsec - ts0.nsec, 1000);
    std.debug.print(
        "sections {d}, paragraphs {d}, text bytes {d}, non-ascii bytes {d}, valid utf8 {d}, longest {d}, missing refs {d}, links {d}, notes {d}, note bytes {d}, parse {d} us\n",
        .{ book.sections, book.paragraphs.len, bytes, non_ascii, valid, longest, book.missing_refs, links, notes, note_bytes, us },
    );
}
