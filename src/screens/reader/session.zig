//! An open book: its pages, where the reader is, and its highlights.
const std = @import("std");
const Page = @import("../../gfx/page.zig").Page;
const book_model = @import("../../model/book.zig");
const note_rules = @import("../../model/notes.zig");
const stats = @import("../../model/stats.zig");
const bookmarks = @import("../../model/bookmarks.zig");
const icons = @import("../../ui/icons.zig");
const catalog = @import("../../model/catalog.zig");
const os = @import("../../linux/os.zig");
const cache = @import("../../layout/page_cache.zig");
const highlights = @import("../../model/highlights.zig");
const state = @import("../../linux/state.zig");
const text = @import("../../layout/text.zig");
const nowUs = os.nowUs;
const unixTime = os.unixTime;
const failed = os.failed;
const app = @import("../../app.zig");

/// What's typed into search.
pub const Query = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn slice(q: *const Query) []const u8 {
        return q.buf[0..q.len];
    }

    pub fn push(q: *Query, c: u8) void {
        if (q.len < q.buf.len) {
            q.buf[q.len] = c;
            q.len += 1;
        }
    }

    pub fn pop(q: *Query) void {
        q.len -|= 1;
    }
};

pub const Session = struct {
    app: *app.App,
    paragraphs: []const book_model.Paragraph,
    pages: []const text.Pos,
    current: usize,
    anchor: text.Pos, // What the reader is at. Settings changes keep to this, not the page edge
    note_parts: [note_rules.max_note_parts]book_model.Paragraph = undefined,
    note_len: usize = 0,
    note_top: u32 = 0,
    note_next: ?text.Pos = null,
    highlights: std.ArrayList(highlights.Highlight) = .empty,
    bookmarks: std.ArrayList(bookmarks.Bookmark) = .empty,
    query: Query = .{}, // The last search, kept while the book is open
    chapters: []const book_model.Chapter = &.{},
    text_before: []const u64 = &.{}, // Bytes of text before each paragraph, for time left
    shown_us: u64 = 0, // When the reader started on this page; 0 while not reading
    seconds_read: u64 = 0, // Time spent in this book, saved with the position

    /// Bytes of text from the start of the book to a position.
    pub fn textAt(s: *const Session, p: text.Pos) u64 {
        return s.text_before[p.para] + p.byte;
    }

    fn textOnPage(s: *const Session, index: usize) u64 {
        const end = if (s.pageEnd(index)) |e| s.textAt(e) else s.text_before[s.text_before.len - 1];
        return end -| s.textAt(s.pages[index]);
    }

    /// Minutes left in the chapter and in the book from a page, once speed is known.
    pub fn timeLeft(s: *const Session, index: usize) struct { chapter: ?u64, book: ?u64 } {
        const here = s.textAt(s.pages[index]);
        const total = s.text_before[s.text_before.len - 1];
        var chapter_end: ?u64 = null;
        for (s.chapters) |c| {
            const at = s.text_before[c.para];
            if (at > here and (chapter_end == null or at < chapter_end.?)) chapter_end = at;
        }
        const speed = s.app.speed;
        return .{
            .chapter = if (chapter_end) |end| speed.minutesFor(end - here) else if (s.chapters.len > 0) speed.minutesFor(total -| here) else null,
            .book = speed.minutesFor(total -| here),
        };
    }

    /// Counts the time on the page being left. Reading one page forward also teaches
    /// the reading speed.
    fn leavePage(s: *Session, to: usize) void {
        if (s.shown_us == 0) return;
        const seconds = (nowUs() -| s.shown_us) / 1_000_000;
        s.seconds_read += stats.countedSeconds(seconds);
        if (to != s.current + 1) return;
        const speed = &s.app.speed;
        const was_known = speed.known();
        speed.record(s.textOnPage(s.current), seconds);
        // Pages already drawn have no time left on them yet.
        if (!was_known and speed.known()) s.app.forgetPages();
    }

    /// Stops the reading clock while something covers the page, or the Kindle sleeps.
    pub fn pauseClock(s: *Session) void {
        s.leavePage(s.current);
        s.shown_us = 0;
    }

    /// Starts the clock again when the page is back in front of the reader.
    pub fn resumeClock(s: *Session) void {
        if (s.shown_us == 0) s.shown_us = nowUs();
    }

    /// Where a page ends: the next page's start, or null on the last page.
    pub fn pageEnd(s: *const Session, index: usize) ?text.Pos {
        return if (index + 1 < s.pages.len) s.pages[index + 1] else null;
    }

    pub fn isBookmarked(s: *const Session, index: usize) bool {
        return bookmarks.anyOnPage(s.bookmarks.items, s.pages[index], s.pageEnd(index));
    }

    /// Every move to another page comes through here, so reading time stays right.
    pub fn setPage(s: *Session, index: usize) void {
        s.leavePage(index);
        s.current = index;
        s.anchor = s.pages[index];
        if (s.shown_us != 0) s.shown_us = nowUs();
    }

    pub fn referenceAt(s: *Session, x: i32, y: i32) ?u32 {
        const slot = s.app.slotFor(s.current) orelse return null;
        return slot.hits.find(x, y);
    }

    /// "12 min left in chapter" on the left of the footer, the book's on the right.
    fn drawTimeLeft(s: *const Session, page: Page, index: usize) !void {
        const a = s.app;
        const left = s.timeLeft(index);
        const y: i32 = @intCast(a.screen.height - 60);
        const margin: f32 = @floatFromInt(a.layout.margin_x);
        var buf: [48]u8 = undefined;
        var line: [64]u8 = undefined;
        if (left.chapter) |m| {
            const t = std.fmt.bufPrint(&line, "{s} left in chapter", .{stats.formatMinutes(&buf, m)}) catch "";
            try a.footer.draw(page, margin, y, t);
        }
        if (left.book) |m| {
            const t = std.fmt.bufPrint(&line, "{s} left in book", .{stats.formatMinutes(&buf, m)}) catch "";
            try a.footer.draw(page, @as(f32, @floatFromInt(a.screen.width)) - margin - try a.footer.measure(t), y, t);
        }
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
        if (a.settings.time_left) try s.drawTimeLeft(page, index);

        a.slots[victim].page = @intCast(index);
        return buf;
    }

    pub fn show(s: *Session, index: usize, touched_us: ?u64, force_clean: bool) !void {
        const a = s.app;
        s.setPage(index);
        const buf = try s.ensure(index, index);
        @memcpy(a.screen.pixels, buf);
        a.stampClock();
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

pub fn saveProgress(entry: *catalog.Entry, path: [*:0]const u8, s: *Session) void {
    s.pauseClock(); // Counts the page being read; the reader's loop starts it again
    const pos = s.pages[s.current];
    const percent: u32 = @intCast((s.current + 1) * 100 / s.pages.len);
    const now = unixTime();
    state.save(path, .{ .para = book_model.textIndex(s.paragraphs, pos.para), .byte = pos.byte, .percent = percent, .opened = now, .seconds = s.seconds_read });
    app.saveSpeed(s.app);
    entry.percent = percent;
    entry.last = now;
    entry.seconds_read = s.seconds_read;
}

/// Lays out the whole book so going backwards is exact.
pub fn paginate(a: *app.App, alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph) ![]const text.Pos {
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
