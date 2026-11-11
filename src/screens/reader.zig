//! Reading a book: page turns, and routing taps to the toolbar, panel, notes and highlights.
const std = @import("std");
const stats = @import("../model/stats.zig");
const epub = @import("../epub/epub.zig");
const memory = @import("../base/memory.zig");
const book_model = @import("../model/book.zig");
const catalog = @import("../model/catalog.zig");
const os = @import("../linux/os.zig");
const file = @import("../linux/file.zig");
const highlights = @import("../model/highlights.zig");
const kfx = @import("../kindle/kfx.zig");
const library = @import("../ui/library.zig");
const menu = @import("../ui/menu.zig");
const selection = @import("../ui/selection.zig");
const state = @import("../linux/state.zig");
const annotation_db = @import("../kindle/annotation_db.zig");
const lipc = @import("../kindle/lipc.zig");
const hyphen = @import("../layout/hyphen.zig");
const define = @import("reader/define.zig");
const toolbar = @import("../ui/toolbar.zig");
const touch_zones = @import("../kindle/touch.zig");
const input_mod = @import("../kindle/input.zig");
const nowUs = os.nowUs;
const unixTime = os.unixTime;
const app = @import("../app.zig");
const goto = @import("reader/goto.zig");
const local_notes = @import("reader/local_notes.zig");
const more = @import("reader/more.zig");
const picture_view = @import("reader/picture.zig");
const wifi_saver = @import("../kindle/wifi_saver.zig");
const page_store = @import("reader/page_store.zig");
const paginate = @import("reader/paginate.zig");
const search = @import("reader/search.zig");
const bookmark = @import("reader/bookmark.zig");
const bookmarks = @import("../model/bookmarks.zig");
const panel = @import("panel.zig");
const lock = @import("lock.zig");
const sess = @import("reader/session.zig");
const hl = @import("reader/highlight.zig");
const note_view = @import("reader/note.zig");
const controls = @import("reader/controls.zig");

pub const save_every = 10;

pub const clock_check_us = 10 * 1000 * 1000;

pub const Outcome = enum { library, quit };

pub const View = enum { page, toolbar, sheet, panel, note, highlight };

/// Whether an action needs every page laid out first: anything but reading on, as
/// menus, Go To and page numbers count from the start of the book.
fn needsAllPages(action: input_mod.Action, view: View, s: *const sess.Session) bool {
    return switch (action) {
        .tick, .drag, .drag_end => false,
        .tap => |t| switch (view) {
            .page => t.y < touch_zones.top_zone or (input_mod.turnDirection(t.x, s.app.input.width) < 0 and s.current == 0),
            // Text settings and closing don't count pages; the toolbar's other buttons do
            .toolbar, .sheet => switch (toolbar.hit(t.x, t.y, view == .sheet)) {
                .sheet, .close, .stay, .text => false,
                else => true,
            },
            else => true,
        },
        .swipe => |direction| direction < 0 and s.current == 0,
        else => true,
    };
}

/// Turns `delta` pages, stopping at either end, and saves the place every few turns.
fn turnBy(session: *sess.Session, entry: *catalog.Entry, state_path: [*:0]const u8, since_save: *u32, delta: i64, touched_us: ?u64) !void {
    // On a first open, pages ahead may not be laid out yet
    if (delta > 0) try session.layoutUntil(session.current + @as(usize, @intCast(delta)) + 1);
    const last: i64 = @intCast(session.pages.len - 1);
    const target = std.math.clamp(@as(i64, @intCast(session.current)) + delta, 0, last);
    if (target == session.current) return;
    try session.show(@intCast(target), touched_us, false);
    since_save.* += 1;
    if (since_save.* >= save_every) {
        sess.saveProgress(entry, state_path, session);
        since_save.* = 0;
    }
}

pub fn readBook(a: *app.App, entry: *catalog.Entry) !Outcome {
    // The open book: parsed text, pages, highlights. All freed together on close.
    var book_budget = memory.Budget{ .name = "book", .child = std.heap.smp_allocator, .limit = 128 << 20 };
    var arena = std.heap.ArenaAllocator.init(book_budget.allocator());
    // What one action needs, like a Go To list or search results. Emptied after each.
    var scratch_budget = memory.Budget{ .name = "scratch", .child = std.heap.smp_allocator, .limit = 32 << 20 };
    var scratch_arena = std.heap.ArenaAllocator.init(scratch_budget.allocator());
    defer {
        a.pictures.clear(a.alloc); // Its keys point into this book's memory
        scratch_arena.deinit();
        arena.deinit();
        book_budget.report();
        scratch_budget.report();
        a.app_budget.report();
        a.stb_budget.report();
    }
    const alloc = arena.allocator();
    const scratch = scratch_arena.allocator();

    const t0 = nowUs();
    const data = try file.map(entry.path);
    defer file.unmap(data);
    const book = if (entry.isEpub()) try epub.parse(alloc, data) else try kfx.parse(alloc, data);
    book_model.plainBody(book.paragraphs);
    const lang = hyphen.detect(book.paragraphs);
    a.layout.hyphenator = a.hyphenatorFor(lang);
    std.debug.print("language {s}\n", .{if (lang) |l| @tagName(l) else "unknown"});
    const t1 = nowUs();

    var path_buf: [320]u8 = undefined;
    const state_path = try a.statePath(&path_buf, entry.path);
    var pages_buf: [320]u8 = undefined;
    const pages_path = try alloc.dupeSentinel(u8, try page_store.pathFor(&pages_buf, state_path), 0);
    const pages_key = page_store.key(a, data.len);
    const stored_pages = page_store.load(alloc, pages_path, pages_key, book.paragraphs.len);
    const saved = state.load(state_path);
    const from_kindle = state.preferKindle(saved, entry.kindle_last);
    // Without saved breaks, lay out a little from the reader's place and show it at
    // once; the rest follows in idle moments. Stock's place is a percent of the
    // pages, so that one needs them all first.
    var progress: ?paginate.Progressive = null;
    if (stored_pages == null and !from_kindle) {
        var place = book_model.Pos{ .para = book_model.fromTextIndex(book.paragraphs, saved.para), .byte = saved.byte };
        if (place.para >= book.paragraphs.len or place.byte > book.paragraphs[place.para].text.len) place = .{};
        progress = try paginate.Progressive.start(a, alloc, book.paragraphs, place);
        if (progress.?.pages().len == 0) progress = null; // Nothing from there on: lay it all out
    }
    const pages = if (progress) |*p| p.pages() else stored_pages orelse try paginate.book(a, alloc, book.paragraphs);
    if (pages.len == 0) return error.EmptyBook;
    if (stored_pages == null and progress == null) page_store.save(alloc, pages_path, pages_key, pages);
    std.debug.print("open {s}: {d} pages, parsed in {d} ms, {s} in {d} ms\n", .{
        entry.title, pages.len, (t1 - t0) / 1000, if (stored_pages != null) "saved pages" else if (progress != null) "first pages" else "laid out", (nowUs() - t1) / 1000,
    });
    const start = if (progress != null)
        0 // The place itself: the first page laid out
    else if (from_kindle)
        @min(pages.len * entry.kindle_percent / 100, pages.len - 1)
    else
        sess.pageContaining(pages, book_model.fromTextIndex(book.paragraphs, saved.para), saved.byte);

    const stored = try alloc.alloc(u8, 1024 * 1024);
    a.layout.marks = &.{};
    var session = sess.Session{ .app = a, .paragraphs = book.paragraphs, .pages = pages, .current = start, .anchor = pages[start], .chapters = book.chapters, .seconds_read = saved.seconds, .pages_path = pages_path, .book_bytes = data.len };
    if (progress) |*p| session.progress = p;
    const words_before = try alloc.alloc(u64, book.paragraphs.len + 1);
    words_before[0] = 0;
    for (book.paragraphs, 0..) |p, i| words_before[i + 1] = words_before[i] + (if (p.note) 0 else stats.countWords(p.text));
    session.words_before = words_before;
    if (entry.isEpub()) {
        var notes_buf: [320]u8 = undefined;
        session.notes_path = try alloc.dupeSentinel(u8, try state.sibling(&notes_buf, state_path, "notes"), 0);
    }
    const highlight_lines = if (entry.isEpub()) try local_notes.read(alloc, session.notes_path, .highlight) else annotation_db.readAnnotations(entry.key, .highlight, stored);
    try session.highlights.appendSlice(alloc, try highlights.parse(alloc, book.paragraphs, highlight_lines));
    const bookmark_lines = if (entry.isEpub()) try local_notes.read(alloc, session.notes_path, .bookmark) else annotation_db.readAnnotations(entry.key, .bookmark, stored);
    try session.bookmarks.appendSlice(alloc, try bookmarks.parse(alloc, book.paragraphs, bookmark_lines));
    std.debug.print("{d} bookmarks loaded\n", .{session.bookmarks.items.len});
    std.debug.print("{d} highlights loaded\n", .{session.highlights.items.len});
    try hl.refreshMarks(a, &session, alloc);
    try session.show(start, null, true);
    sess.saveProgress(entry, state_path, &session);

    var since_save: u32 = 0;
    // A while into the book, Wi-Fi goes off; leaving it, it comes back
    const wifi_off_at = nowUs() + wifi_saver.after_us;
    var wifi_tried = false;
    var battery_minute: u64 = 0; // The battery is noted once a minute at most
    defer wifi_saver.restore();
    var view: View = .page;
    var active: ?[]const u8 = null;
    var delete_top: ?usize = null;
    a.input.grips = true;
    a.input.tick_us = clock_check_us;
    defer a.input.grips = true;
    defer a.input.tick_us = 0;
    defer sess.saveProgress(entry, state_path, &session);
    defer a.input.deferred = false;
    defer a.input.edge_zones = true;
    while (true) {
        _ = scratch_arena.reset(.retain_capacity); // Nothing from the last action is still needed
        // The reading clock runs only while the page itself is in front of the reader.
        if (view == .page) session.resumeClock() else session.pauseClock();
        a.input.deferred = view == .page;
        a.input.edge_zones = view != .highlight;
        // A first open's layout goes on in idle moments, about 40 ms at a time
        a.input.tick_us = if (session.layoutPending()) 1000 else clock_check_us;
        const action = a.input.next();
        if (session.layoutPending() and needsAllPages(action, view, &session)) try session.finishLayout();
        switch (action) {
            .unlock => {},
            .hold => |h| {
                if (view != .page) continue;
                // Holding a picture shows it on the whole screen
                if (session.pictureAt(h.x, h.y)) |img| {
                    a.input.drag_slot = null;
                    session.pauseClock();
                    try picture_view.show(a, img);
                    continue;
                }
                // Holding an existing highlight selects it, rather than starting over it.
                if (selection.wordUnder(hl.pageWords(a, &session), h.x, h.y)) |word| {
                    if (highlights.atWord(session.highlights.items, word)) |id| {
                        a.input.drag_slot = null;
                        active = id;
                        view = .highlight;
                        delete_top = try hl.showPage(a, &session, active);
                        continue;
                    }
                }
                const held = try hl.selectFromHold(a, &session, h.x, h.y) orelse continue;
                // Held without moving: look the word up, and highlight it only if asked
                if (held.head == held.fixed) {
                    const word = hl.pageWords(a, &session)[held.fixed];
                    if (try define.run(a, &session, word, lang) == .close) {
                        _ = try hl.showPage(a, &session, null); // Takes the underline off
                        continue;
                    }
                }
                active = try hl.newHighlight(a, &session, alloc, entry, held.fixed, held.head);
                if (active != null) {
                    view = .highlight;
                    delete_top = try hl.showPage(a, &session, active);
                }
            },
            .lock => {
                session.pauseClock(); // Asleep isn't reading
                try lock.lockScreen(a, entry);
                a.noteBattery(); // What sleeping cost
                if (view == .page) try a.updateClock();
            },
            .tap => |t| switch (view) {
                .highlight => {
                    const id = active.?;
                    const words = hl.pageWords(a, &session);
                    const range = highlights.wordRange(words, session.highlights.items, id);
                    if (delete_top) |top| {
                        if (hl.inDeleteBubble(a, top, t.x, t.y)) {
                            try hl.removeHighlight(a, &session, alloc, entry, id);
                            view = .page;
                            active = null;
                            delete_top = try hl.showPage(a, &session, null);
                            continue;
                        }
                    }
                    if (range) |r| {
                        const chosen = words[r.lo .. r.hi + 1];
                        const grab_start = selection.nearHandle(selection.startHandle(chosen), t.x, t.y);
                        if (grab_start or selection.nearHandle(selection.endHandle(chosen), t.x, t.y)) {
                            try hl.extendHighlight(a, &session, alloc, entry, id, grab_start);
                            delete_top = try hl.showPage(a, &session, active);
                            continue;
                        }
                    }
                    view = .page;
                    active = null;
                    delete_top = try hl.showPage(a, &session, null);
                },
                .note => {
                    if (t.y >= session.note_top and session.note_next != null) {
                        try note_view.showNote(a, &session, session.note_next.?, a.screen.height - session.note_top);
                    } else {
                        view = .page;
                        try note_view.closeNote(a, &session);
                    }
                },
                .panel => {
                    const choice = menu.hit(t.x, t.y);
                    const page = try session.ensure(session.current, session.current);
                    if (try panel.panelControl(a, page, choice, t.x)) continue;
                    switch (choice) {
                        .settings => {
                            lipc.openSettings();
                            return .quit;
                        },
                        .kindle => return .quit, // noface.sh brings back the Kindle's home
                        .close => {
                            view = .page;
                            try panel.closeMenu(a, page);
                            try a.updateClock();
                        },
                        else => {},
                    }
                },
                .toolbar, .sheet => {
                    const sheet = view == .sheet;
                    switch (toolbar.hit(t.x, t.y, sheet)) {
                        .stay => {},
                        .more => switch (try more.run(a, &session, entry)) {
                            .stay => try controls.drawToolbar(a, &session, entry.title, sheet, true),
                            .page => |target| {
                                view = .page;
                                a.input.grips = true;
                                try session.show(target, null, true);
                            },
                            .refresh => {
                                view = .page;
                                a.input.grips = true;
                                try session.show(session.current, null, true);
                            },
                        },
                        .search => {
                            if (try search.run(a, &session, scratch)) |target| {
                                view = .page;
                                a.input.grips = true;
                                try session.show(target, null, true);
                            } else {
                                try controls.drawToolbar(a, &session, entry.title, sheet, true);
                            }
                        },
                        .bookmark => {
                            try bookmark.toggle(a, &session, alloc, entry);
                            try controls.drawToolbar(a, &session, entry.title, sheet, true);
                        },
                        .goto => {
                            if (try goto.run(a, &session, scratch, book.chapters)) |target| {
                                view = .page;
                                a.input.grips = true;
                                try session.show(target, null, true);
                            } else {
                                try controls.drawToolbar(a, &session, entry.title, sheet, true);
                            }
                        },
                        .close => {
                            view = .page;
                            a.input.grips = true;
                            try controls.closeToolbar(a, &session, sheet);
                            try a.updateClock();
                        },
                        .home => return .library,
                        .text => {
                            view = if (sheet) .toolbar else .sheet;
                            // Shrinking needs the page back under where the sheet was.
                            try controls.drawToolbar(a, &session, entry.title, view == .sheet, sheet);
                        },
                        .chapter_prev, .chapter_next => |direction| {
                            const sections = try scratch.alloc(u32, session.pages.len);
                            for (session.pages, sections) |p, *out| out.* = session.paragraphs[p.para].section;
                            session.setPage(toolbar.chapterTarget(sections, session.current, direction == .chapter_next));
                            try controls.drawToolbar(a, &session, entry.title, sheet, true);
                        },
                        .scrub => try controls.dragScrub(a, &session, entry.title, sheet, t.x),
                        .sheet => try controls.tapSheet(a, alloc, &session, entry.title, t.x, t.y),
                    }
                },
                .page => {
                    if (selection.wordUnder(hl.pageWords(a, &session), t.x, t.y)) |word| {
                        if (highlights.atWord(session.highlights.items, word)) |id| {
                            active = id;
                            view = .highlight;
                            delete_top = try hl.showPage(a, &session, active);
                            continue;
                        }
                    }
                    if (session.referenceAt(t.x, t.y)) |target| {
                        view = .note;
                        try note_view.openNote(a, &session, target);
                        continue;
                    }
                    if (t.y < touch_zones.top_zone) {
                        view = .toolbar;
                        a.input.grips = false;
                        // Drawn with the last status at once, then again if it changed
                        try controls.drawToolbar(a, &session, entry.title, false, false);
                        const fresh = lipc.read(a.quick);
                        if (!fresh.same(&a.quick)) {
                            a.quick = fresh;
                            try controls.drawToolbar(a, &session, entry.title, false, false);
                        }
                        continue;
                    }
                    const delta = input_mod.turnDirection(t.x, a.input.width) + a.input.takeTurns();
                    try turnBy(&session, entry, state_path, &since_save, delta, t.us);
                },
            },
            .swipe => |direction| {
                if (view != .page) continue;
                try turnBy(&session, entry, state_path, &since_save, direction + a.input.takeTurns(), null);
            },
            .tick => {
                if (session.layoutPending()) {
                    // Once done, show the page count that was missing: in the footer,
                    // or in the toolbar when it's open
                    if (try session.layoutStep()) switch (view) {
                        .page => try session.showFooter(),
                        .toolbar, .sheet => try controls.drawToolbar(a, &session, entry.title, view == .sheet, false),
                        else => {},
                    };
                    continue;
                }
                if (view == .page and !wifi_tried and nowUs() >= wifi_off_at) {
                    wifi_tried = true;
                    _ = wifi_saver.pause();
                }
                if (unixTime() / 60 != battery_minute) {
                    battery_minute = unixTime() / 60;
                    a.noteBattery();
                }
                if (view == .page and unixTime() / 60 != a.clock_minute) try a.updateClock();
            },
            .drag, .drag_end => {},
            .pull => {
                if (view != .page) continue;
                view = .panel;
                try panel.drawFresh(a, try session.ensure(session.current, session.current));
            },
            .power, .computer, .stop => return .quit,
        }
    }
}
