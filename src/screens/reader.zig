//! Reading a book: page turns, and routing taps to the toolbar, panel, notes and highlights.
const std = @import("std");
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
const toolbar = @import("../ui/toolbar.zig");
const touch_zones = @import("../kindle/touch.zig");
const input_mod = @import("../kindle/input.zig");
const nowUs = os.nowUs;
const unixTime = os.unixTime;
const app = @import("../app.zig");
const goto = @import("reader/goto.zig");
const more = @import("reader/more.zig");
const page_store = @import("reader/page_store.zig");
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
    const book = try kfx.parse(alloc, data);
    const t1 = nowUs();

    var path_buf: [320]u8 = undefined;
    const state_path = try a.statePath(&path_buf, entry.path);
    var pages_buf: [320]u8 = undefined;
    const pages_path = try alloc.dupeSentinel(u8, try page_store.pathFor(&pages_buf, state_path), 0);
    const pages_key = page_store.key(a, data.len);
    const stored_pages = page_store.load(alloc, pages_path, pages_key);
    const pages = stored_pages orelse try sess.paginate(a, alloc, book.paragraphs);
    if (pages.len == 0) return error.EmptyBook;
    if (stored_pages == null) page_store.save(alloc, pages_path, pages_key, pages);
    std.debug.print("open {s}: {d} pages, parsed in {d} ms, {s} in {d} ms\n", .{
        entry.title, pages.len, (t1 - t0) / 1000, if (stored_pages != null) "saved pages" else "laid out", (nowUs() - t1) / 1000,
    });
    const saved = state.load(state_path);
    const start = if (state.preferKindle(saved, entry.kindle_last))
        @min(pages.len * entry.kindle_percent / 100, pages.len - 1)
    else
        sess.pageContaining(pages, book_model.fromTextIndex(book.paragraphs, saved.para), saved.byte);

    const stored = try alloc.alloc(u8, 1024 * 1024);
    a.layout.marks = &.{};
    var session = sess.Session{ .app = a, .paragraphs = book.paragraphs, .pages = pages, .current = start, .anchor = pages[start], .chapters = book.chapters, .seconds_read = saved.seconds, .pages_path = pages_path, .book_bytes = data.len };
    const text_before = try alloc.alloc(u64, book.paragraphs.len + 1);
    text_before[0] = 0;
    for (book.paragraphs, 0..) |p, i| text_before[i + 1] = text_before[i] + (if (p.note) 0 else p.text.len);
    session.text_before = text_before;
    try session.highlights.appendSlice(alloc, try highlights.parse(alloc, book.paragraphs, annotation_db.readAnnotations(entry.key, .highlight, stored)));
    try session.bookmarks.appendSlice(alloc, try bookmarks.parse(alloc, book.paragraphs, annotation_db.readAnnotations(entry.key, .bookmark, stored)));
    std.debug.print("{d} bookmarks loaded\n", .{session.bookmarks.items.len});
    std.debug.print("{d} highlights loaded\n", .{session.highlights.items.len});
    try hl.refreshMarks(a, &session, alloc);
    try session.show(start, null, true);
    sess.saveProgress(entry, state_path, &session);

    var since_save: u32 = 0;
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
        switch (a.input.next()) {
            .unlock => {},
            .hold => |h| {
                if (view != .page) continue;
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
                active = try hl.newHighlight(a, &session, alloc, entry, h.x, h.y);
                if (active != null) {
                    view = .highlight;
                    delete_top = try hl.showPage(a, &session, active);
                }
            },
            .lock => {
                session.pauseClock(); // Asleep isn't reading
                try lock.lockScreen(a, entry);
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
                        a.quick = lipc.read(a.quick);
                        try controls.drawToolbar(a, &session, entry.title, false, false);
                        continue;
                    }
                    const delta = input_mod.turnDirection(t.x, a.input.width) + a.input.takeTurns();
                    const last: i64 = @intCast(session.pages.len - 1);
                    const target = std.math.clamp(@as(i64, @intCast(session.current)) + delta, 0, last);
                    if (target == session.current) continue;
                    try session.show(@intCast(target), t.us, false);
                    since_save += 1;
                    if (since_save >= save_every) {
                        sess.saveProgress(entry, state_path, &session);
                        since_save = 0;
                    }
                },
            },
            .tick => {
                if (view == .page and unixTime() / 60 != a.clock_minute) try a.updateClock();
            },
            .drag, .drag_end => {},
            .pull => {
                if (view != .page) continue;
                view = .panel;
                a.quick = lipc.read(a.quick);
                try panel.drawMenu(a, try session.ensure(session.current, session.current));
            },
            .power, .idle, .stop => return .quit,
        }
    }
}
