//! Making, extending and deleting highlights on the page.
const std = @import("std");
const draw = @import("../../ui/draw.zig");
const catalog = @import("../../book/catalog.zig");
const os = @import("../../platform/os.zig");
const annotations = @import("../../book/annotations.zig");
const highlights = @import("../../book/highlights.zig");
const kfx = @import("../../book/kfx.zig");
const library = @import("../../ui/library.zig");
const selection = @import("../../ui/selection.zig");
const system = @import("../../platform/system.zig");
const text = @import("../../book/text.zig");
const unixTime = os.unixTime;
const failed = os.failed;
const app = @import("../../app.zig");
const sess = @import("session.zig");

pub fn pointFor(s: *sess.Session, para: u32, byte: u32) ?annotations.Point {
    const p = s.paragraphs[para];
    if (p.position == 0) return null;
    const chars = kfx.charOffset(p.text, byte);
    return .{ .element = p.element, .offset = chars, .short = p.position + chars };
}

pub fn saveHighlight(s: *sess.Session, entry: *const catalog.Entry, id: []const u8, span: highlights.Span) bool {
    if (system.dryRun()) return true;
    if (!system.safeId(entry.key) or !system.safeId(entry.kind) or !system.safeId(id) or !system.safeGuid(entry.guid)) return false;
    const start = pointFor(s, span.first_para, span.first_byte) orelse return false;
    const end = pointFor(s, span.last_para, span.last_byte) orelse return false;
    var buf: [1200]u8 = undefined;
    const sql = annotations.insertSql(&buf, .{
        .id = id,
        .key = entry.key,
        .kind = entry.kind,
        .guid = entry.guid,
        .start = start,
        .end = end,
        .now_ms = unixTime() * 1000,
    }) catch return false;
    return system.runAnnotationSql(sql);
}

pub fn pageWords(a: *app.App, s: *const sess.Session) []const text.Word {
    const slot = a.slotFor(s.current) orelse return &.{};
    return slot.hits.words[0..slot.hits.word_count];
}

/// Rebuilds the marks drawn on pages, after highlights change.
pub fn refreshMarks(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !void {
    const marks = try alloc.alloc(text.Mark, s.highlights.items.len);
    for (s.highlights.items, marks) |h, *m| m.* = h.mark;
    a.layout.marks = marks;
    a.forgetPages();
}

/// Shows the page, with handles on a highlight when one is active.
pub fn showPage(a: *app.App, s: *sess.Session, active: ?[]const u8) !?usize {
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    a.stampClock();
    var delete_top: ?usize = null;
    if (active) |id| {
        const words = pageWords(a, s);
        if (highlights.wordRange(words, s.highlights.items, id)) |r| {
            const screen_page = a.page(a.screen.pixels);
            const chosen = words[r.lo .. r.hi + 1];
            selection.draw(screen_page, chosen);
            const band = selection.band(chosen);
            delete_top = try drawDeleteBubble(a, band);
        }
    }
    try a.screen.waitComplete(try a.screen.update(app.page_waveform, .partial));
    return delete_top;
}

/// Takes a failed selection back off the page and says so.
pub fn highlightNotSaved(a: *app.App, s: *sess.Session) !void {
    _ = try showPage(a, s, null);
    try app.showNotice(a, "This highlight couldn't be saved.");
    _ = try showPage(a, s, null);
}

pub const bubble_width = 240;

pub const bubble_height = 96;

pub fn drawDeleteBubble(a: *app.App, band: selection.Band) !usize {
    const screen_page = a.page(a.screen.pixels);
    const below = band.top + band.height + 12;
    const top: u32 = if (below + bubble_height < a.screen.height - 130) below else band.top -| (bubble_height + 12);
    const left = (a.screen.width - bubble_width) / 2;
    screen_page.fillRect(left - 4, top - 4, bubble_width + 8, bubble_height + 8, 0xff);
    draw.box(screen_page, left, top, bubble_width, bubble_height);
    try draw.centered(a.ui.small, screen_page, @floatFromInt(a.screen.width / 2), @intCast(top + 62), "Delete");
    return top;
}

pub fn inDeleteBubble(a: *app.App, top: usize, x: i32, y: i32) bool {
    const left: i32 = @intCast((a.screen.width - bubble_width) / 2);
    const t: i32 = @intCast(top);
    return x >= left and x < left + bubble_width and y >= t and y < t + bubble_height;
}

/// Follows a finger, keeping `fixed` in place, and returns where it stopped.
pub fn dragSelection(a: *app.App, words: []const text.Word, fixed: usize, moving: usize) !usize {
    var head = moving;
    @memcpy(a.lock_cover, a.screen.pixels);
    a.page(a.lock_cover).threshold(0, a.screen.height); // Pure black and white for A2
    var previous = try paintSelection(a, words, fixed, head, .{ .top = 0, .height = 0 });
    const Follow = struct {
        a: *app.App,
        words: []const text.Word,
        fixed: usize,
        head: *usize,
        previous: *selection.Band,
        pub fn moved(f: @This(), x: i32, y: i32) !?u32 {
            const next = selection.wordAt(f.words, x, y) orelse return null;
            if (next == f.head.*) return null;
            f.head.* = next;
            f.previous.* = try paintSelection(f.a, f.words, f.fixed, next, f.previous.*);
            return f.a.screen.next_marker - 1;
        }
    };
    try app.followDrag(a, a.screen.next_marker - 1, Follow{ .a = a, .words = words, .fixed = fixed, .head = &head, .previous = &previous });
    return head;
}

/// Underlines from `first` to `last`, redrawing the band the old and new selections cover.
fn paintSelection(a: *app.App, list: []const text.Word, first: usize, last: usize, old: selection.Band) !selection.Band {
    const lo = @min(first, last);
    const hi = @max(first, last);
    const chosen = list[lo .. hi + 1];
    const now = selection.band(chosen);
    const top = if (old.height == 0) now.top else @min(old.top, now.top);
    const bottom = @min(@max(old.top + old.height, now.top + now.height), a.screen.height);
    const stride = a.screen.stride;
    @memcpy(a.screen.pixels[top * stride .. bottom * stride], a.lock_cover[top * stride .. bottom * stride]);
    selection.draw(a.page(a.screen.pixels), chosen);
    _ = try a.screen.updateRegion(0, top, a.screen.width, bottom - top, .a2, .partial);
    return now;
}

/// Press and hold: makes a new highlight from what the finger covers.
pub fn newHighlight(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry, hold_x: i32, hold_y: i32) !?[]const u8 {
    const words = pageWords(a, s);
    const fixed = selection.wordAt(words, hold_x, hold_y) orelse return null;
    const head = try dragSelection(a, words, fixed, fixed);
    const lo = words[@min(fixed, head)];
    const hi = words[@max(fixed, head)];
    const start = pointFor(s, lo.para, lo.start) orelse {
        try highlightNotSaved(a, s);
        return null;
    };
    const id = try highlights.freeId(alloc, s.highlights.items, start.short);
    const saved = saveHighlight(s, entry, id, highlights.Span.of(lo, hi));
    if (saved and !system.dryRun()) system.syncNow();
    std.debug.print("highlight {s}: {d} words, saved {}\n", .{ id, @max(fixed, head) - @min(fixed, head) + 1, saved });
    if (!saved) {
        try highlightNotSaved(a, s);
        return null;
    }
    try highlights.add(&s.highlights, alloc, s.paragraphs, id, highlights.Span.of(lo, hi));
    try refreshMarks(a, s, alloc);
    return id;
}

/// Drags one end of a highlight. The record keeps its ID, so it extends in place.
pub fn extendHighlight(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry, id: []const u8, grab_start: bool) !void {
    const words = pageWords(a, s);
    const range = highlights.wordRange(words, s.highlights.items, id) orelse return;
    const whole = highlights.extent(s.highlights.items, id) orelse return;
    a.input.beginDrag();
    const fixed = if (grab_start) range.hi else range.lo;
    const moving = if (grab_start) range.lo else range.hi;
    const head = try dragSelection(a, words, fixed, moving);
    if (head == moving) return; // Touched without moving, so nothing changed
    const crossed = if (grab_start) head > fixed else head < fixed;
    const span = highlights.dragged(whole, words[fixed], words[head], grab_start, crossed);
    const saved = saveHighlight(s, entry, id, span);
    if (saved and !system.dryRun()) system.syncNow();
    std.debug.print("highlight extended: saved {}\n", .{saved});
    if (!saved) return app.showNotice(a, "This highlight couldn't be changed.");
    highlights.remove(&s.highlights, id);
    try highlights.add(&s.highlights, alloc, s.paragraphs, id, span);
    try refreshMarks(a, s, alloc);
}

/// Deletes a highlight here and, through sync, everywhere.
pub fn removeHighlight(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry, id: []const u8) !void {
    if (!system.dryRun()) {
        var buf: [900]u8 = undefined;
        const safe = system.safeId(id) and system.safeId(entry.key);
        const sql = try annotations.deleteSql(&buf, id, entry.key, unixTime() * 1000);
        const removed = safe and system.runAnnotationSql(sql);
        std.debug.print("highlight removed: {}\n", .{removed});
        if (!removed) return app.showNotice(a, "This highlight couldn't be deleted.");
        system.syncNow();
    }
    highlights.remove(&s.highlights, id);
    try refreshMarks(a, s, alloc);
}
