//! An open book: its pages, where the reader is, and its highlights.
const std = @import("std");
const bookmarks = @import("../../book/bookmarks.zig");
const icons = @import("../../ui/icons.zig");
const catalog = @import("../../book/catalog.zig");
const os = @import("../../platform/os.zig");
const cache = @import("../../platform/cache.zig");
const highlights = @import("../../book/highlights.zig");
const kfx = @import("../../book/kfx.zig");
const library = @import("../../ui/library.zig");
const menu = @import("../../ui/menu.zig");
const state = @import("../../platform/state.zig");
const text = @import("../../book/text.zig");
const nowUs = os.nowUs;
const unixTime = os.unixTime;
const failed = os.failed;
const app = @import("../../app.zig");

pub const Session = struct {
    app: *app.App,
    paragraphs: []const kfx.Paragraph,
    pages: []const text.Pos,
    current: usize,
    anchor: text.Pos, // What the reader is at. Settings changes keep to this, not the page edge
    note_parts: [kfx.max_note_parts]kfx.Paragraph = undefined,
    note_len: usize = 0,
    note_top: u32 = 0,
    note_next: ?text.Pos = null,
    highlights: std.ArrayList(highlights.Highlight) = .empty,
    bookmarks: std.ArrayList(bookmarks.Bookmark) = .empty,

    /// Where a page ends: the next page's start, or null on the last page.
    pub fn pageEnd(s: *const Session, index: usize) ?text.Pos {
        return if (index + 1 < s.pages.len) s.pages[index + 1] else null;
    }

    pub fn isBookmarked(s: *const Session, index: usize) bool {
        return bookmarks.anyOnPage(s.bookmarks.items, s.pages[index], s.pageEnd(index));
    }

    pub fn setPage(s: *Session, index: usize) void {
        s.current = index;
        s.anchor = s.pages[index];
    }

    pub fn referenceAt(s: *Session, x: i32, y: i32) ?u32 {
        const slot = s.app.slotFor(s.current) orelse return null;
        return slot.hits.find(x, y);
    }

    /// Get a rendered page, reusing a cached one when possible.
    pub fn ensure(s: *Session, index: usize, center: usize) ![]const u8 {
        const a = s.app;
        if (a.slotFor(index)) |slot| return slot.buf;
        var cached: [3]i64 = undefined;
        for (&a.slots, &cached) |*slot, *c| c.* = slot.page;
        const victim = cache.victim(cached, @intCast(center));
        const buf = a.slots[victim].buf;
        const page = a.page(buf);
        a.slots[victim].hits.clear();
        _ = try text.renderPage(a.body, page, s.paragraphs, s.pages[index], a.layout, &a.slots[victim].hits);

        var label: [32]u8 = undefined;
        const counter = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, s.pages.len }) catch "";
        const x = @as(f32, @floatFromInt(a.screen.width)) / 2 - 50;
        try a.footer.draw(page, x, @intCast(a.screen.height - 60), counter);
        if (s.isBookmarked(index)) icons.ribbon(page, a.screen.width);

        a.slots[victim].page = @intCast(index);
        return buf;
    }

    pub fn show(s: *Session, index: usize, touched_us: ?u64, force_clean: bool) !void {
        const a = s.app;
        const buf = try s.ensure(index, index);
        @memcpy(a.screen.pixels, buf);
        a.stampClock();
        s.setPage(index);
        a.turns += 1;
        const clean = force_clean or (a.settings.refresh and a.turns % 20 == 0);
        const marker = if (clean)
            try a.screen.update(.gc16, .full)
        else
            try a.screen.update(app.page_waveform, .partial);
        const queued = nowUs();
        try a.screen.waitComplete(marker);
        const done = nowUs();
        if (touched_us) |t| {
            std.debug.print("turn to {d}: touch to queued {d} us, touch to done {d} ms{s}\n", .{
                index + 1, queued -| t, (done -| t) / 1000, if (clean) " (clean)" else "",
            });
        }
        for (&a.slots) |*slot| {
            if (slot.page != @as(i64, @intCast(index))) continue;
            for (slot.hits.items[0..slot.hits.len]) |h| {
                std.debug.print("ref page {d} at {d},{d} size {d}x{d} target {d}\n", .{ index + 1, h.x, h.y, h.w, h.h, h.target });
            }
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < s.pages.len) _ = try s.ensure(index + 1, index);
        if (index > 0) _ = try s.ensure(index - 1, index);
    }
};

pub fn saveProgress(entry: *catalog.Entry, path: [*:0]const u8, s: *const Session) void {
    const pos = s.pages[s.current];
    const percent: u32 = @intCast((s.current + 1) * 100 / s.pages.len);
    const now = unixTime();
    state.save(path, .{ .para = pos.para, .byte = pos.byte, .percent = percent, .opened = now });
    entry.percent = percent;
    entry.last = now;
}

/// Lays out the whole book so going backwards is exact.
pub fn paginate(a: *app.App, alloc: std.mem.Allocator, paragraphs: []const kfx.Paragraph) ![]const text.Pos {
    const geometry = a.page(&.{});
    var pages: std.ArrayList(text.Pos) = .empty;
    var pos = text.Pos{};
    while (pos.para < paragraphs.len) {
        try pages.append(alloc, pos);
        const next = try text.layoutPage(a.body, null, geometry, paragraphs, pos, a.layout, null);
        if (next.para == pos.para and next.byte == pos.byte) break;
        pos = next;
    }
    return pages.items;
}

pub fn pageContaining(pages: []const text.Pos, para: usize, byte: usize) usize {
    var found: usize = 0;
    for (pages, 0..) |p, i| {
        if (p.para < para or (p.para == para and p.byte <= byte)) found = i;
    }
    return found;
}

/// Re-lays out the book after a text setting changed, keeping the reading position.
pub fn relayout(a: *app.App, alloc: std.mem.Allocator, s: *Session) !void {
    a.applySettings() catch |err| {
        std.debug.print("settings failed: {s}\n", .{@errorName(err)});
        a.settings = app.loadSettings(a.settings_path);
        return a.applySettings();
    };
    app.saveSettings(a.settings_path, a.settings);
    a.forgetPages();
    s.pages = try paginate(a, alloc, s.paragraphs);
    s.current = pageContaining(s.pages, s.anchor.para, s.anchor.byte);
    std.debug.print("relayout: page {d} of {d}, anchor {d}:{d}\n", .{ s.current + 1, s.pages.len, s.anchor.para, s.anchor.byte });
}
