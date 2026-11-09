//! Laying out a whole book into pages. Kept apart from the rest of the reader because
//! saved page breaks are only valid for this code: page_store fingerprints this file.
const std = @import("std");
const app = @import("../../app.zig");
const book_model = @import("../../model/book.zig");
const check = @import("../../base/check.zig");
const text = @import("../../layout/text.zig");

/// Lays out the whole book so going backwards is exact.
pub fn book(a: *app.App, alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph) ![]const book_model.Pos {
    const geometry = a.page(&.{});
    var pages: std.ArrayList(book_model.Pos) = .empty;
    var pos = book_model.Pos{};
    while (pos.para < paragraphs.len) {
        try pages.append(alloc, pos);
        const next = try text.layoutPage(a.body, null, geometry, paragraphs, pos, a.layout, null);
        // A page that fits nothing would repeat forever; layout always places something.
        check.thatf(next.para > pos.para or (next.para == pos.para and next.byte > pos.byte), "page at {d}:{d} moves forward", .{ pos.para, pos.byte });
        pos = next;
    }
    return pages.items;
}
