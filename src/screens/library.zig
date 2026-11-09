//! The home screen: the library, a book's actions, and opening books.
const std = @import("std");
const dir = @import("../linux/dir.zig");
const epub = @import("../epub/epub.zig");
const card = @import("../ui/card.zig");
const catalog = @import("../model/catalog.zig");
const os = @import("../linux/os.zig");
const file = @import("../linux/file.zig");
const kfx = @import("../kindle/kfx.zig");
const library = @import("../ui/library.zig");
const book_actions = @import("../ui/sheet.zig");
const state = @import("../linux/state.zig");
const catalog_db = @import("../kindle/catalog.zig");
const lipc = @import("../kindle/lipc.zig");
const store = @import("../kindle/store.zig");
const nowUs = os.nowUs;
const app = @import("../app.zig");
const panel = @import("panel.zig");
const lock = @import("lock.zig");
const reader = @import("reader.zig");
const keyboard = @import("../ui/keyboard.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const search = @import("../model/search.zig");

pub const download_poll_us = 5 * 1000 * 1000;

pub const download_watch_us = 3 * 60 * 1000 * 1000;

pub fn loggedHit(x: i32, y: i32, index: usize, count: usize, searching: bool) library.Hit {
    const h = library.hit(x, y, index, count, searching);
    std.debug.print("library tap {d},{d}: {s}\n", .{ x, y, @tagName(h) });
    return h;
}

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    entries: []catalog.Entry,
    visible: []usize,

    fn deinit(l: *Library) void {
        l.arena.deinit();
        file.unmap(l.data);
    }

    fn localCount(l: *const Library) usize {
        var n: usize = 0;
        for (l.entries) |e| {
            if (e.isLocal()) n += 1;
        }
        return n;
    }
};

const documents = "/mnt/us/documents";

/// EPUBs copied over the cable. The Kindle's catalog doesn't list them, so noface finds
/// them itself, reading title and author from each book, and its cover once into a file
/// beside the book's state.
fn addEpubs(a: *app.App, alloc: std.mem.Allocator, catalog_entries: []catalog.Entry) ![]catalog.Entry {
    const paths = dir.findFiles(alloc, documents, ".epub") catch return catalog_entries;
    if (paths.len == 0) return catalog_entries;
    var out: std.ArrayList(catalog.Entry) = .empty;
    try out.appendSlice(alloc, catalog_entries);
    var path_buf: [320]u8 = undefined;
    var cover_buf: [320]u8 = undefined;
    next: for (paths) |path| {
        for (catalog_entries) |e| {
            if (std.mem.eql(u8, e.path, path)) continue :next;
        }
        const data = file.map(path) catch continue;
        defer file.unmap(data);
        const state_path = try a.statePath(&path_buf, path);
        const cover_path = try state.sibling(&cover_buf, state_path, "cover");
        const have_cover = if (file.map(cover_path)) |c| blk: {
            file.unmap(c);
            break :blk true;
        } else |_| false;
        const about = epub.info(alloc, data, !have_cover) catch continue;
        if (about.cover) |bytes| state.writeSmall(cover_path, bytes);
        const saved = state.load(state_path);
        try out.append(alloc, .{
            .path = path,
            .title = if (about.title.len > 0) about.title else std.fs.path.stem(path),
            .author = about.author,
            .percent = @min(saved.percent orelse 0, 100),
            .last = saved.opened,
            .seconds_read = saved.seconds,
            .thumbnail = if (have_cover or about.cover != null) try alloc.dupeSentinel(u8, cover_path, 0) else "",
            .kind = "EPUB",
        });
    }
    return out.items;
}

/// The catalog's downloading flag can stay set long after a download ended, so
/// the file decides: a partial book points past its own end.
pub fn isCompleteBook(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    const data = file.map(path) catch return false;
    defer file.unmap(data);
    return kfx.isComplete(data);
}

pub fn loadLibrary(a: *app.App) !Library {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const data = try file.map(a.library_path);
    const entries = try catalog_db.parse(alloc, data);
    var path_buf: [320]u8 = undefined;
    for (entries) |*e| {
        if (e.availability == .downloading and isCompleteBook(e.path)) e.availability = .local;
        if (!e.isLocal()) continue;
        const saved = state.load(try a.statePath(&path_buf, e.path));
        e.seconds_read = saved.seconds;
        if (state.preferKindle(saved, e.kindle_last)) continue;
        if (saved.percent) |p| e.percent = @min(p, 100);
        e.last = @max(e.last, saved.opened);
    }
    const all = try addEpubs(a, alloc, entries);
    return .{ .arena = arena, .data = data, .entries = all, .visible = try alloc.alloc(usize, all.len) };
}

/// Saves the book as unread, so the reload that follows doesn't bring back 100%.
/// Dated just after the last time it was opened anywhere: newer than stock's
/// percent, so it wins, without moving the book up in recent order.
pub fn forgetFinished(a: *app.App, e: *const catalog.Entry) !void {
    var path_buf: [320]u8 = undefined;
    const path = try a.statePath(&path_buf, e.path);
    var saved = state.load(path);
    saved.percent = 0;
    saved.opened = @max(saved.opened, e.kindle_last) + 1;
    state.save(path, saved);
}

/// What a book's actions changed, which decides what the library does next.
pub const Change = enum { none, downloading, other };

/// Shows a book's actions.
pub fn bookSheet(a: *app.App, e: *catalog.Entry, background: []const u8) !Change {
    std.debug.print("sheet: {s}\n", .{e.title});
    var confirming = false;
    while (true) {
        var list_buf: [3]book_actions.Option = undefined;
        var row_buf: [3]card.Row = undefined;
        var subtitle_buf: [320]u8 = undefined;
        const list = book_actions.options(e, confirming, &list_buf);
        const subtitle = book_actions.subtitle(&subtitle_buf, e, confirming);
        const picked = try app.chooseFromCard(a, background, e.title, subtitle, book_actions.rows(list, &row_buf)) orelse return .none;
        switch (list[picked]) {
            .cancel => return .none,
            .remove => confirming = true,
            .confirm_remove => {
                store.removeDownload(e.key, e.kind);
                std.debug.print("removed download: {s}\n", .{e.title});
                return .other;
            },
            .download => {
                store.downloadBook(e.key, e.kind);
                std.debug.print("download requested: {s}\n", .{e.title});
                return .downloading;
            },
            .mark_read, .mark_unread => |choice| {
                const done = choice == .mark_read;
                store.markRead(e.key, e.kind, done);
                e.finished = done;
                if (!done and e.isLocal()) forgetFinished(a, e) catch {};
                return .other;
            },
        }
    }
}

pub fn logPage(lib: *const Library, index: usize, count: usize) void {
    const range = library.pageRange(index, count);
    var i = range.first;
    while (i < range.end) : (i += 1) {
        std.debug.print("cell {d} {d} {s}\n", .{ index, i - range.first, lib.entries[lib.visible[i]].title });
    }
}

/// The books to show: the filter's, without the hero, or while searching every match,
/// the hero too.
fn choose(lib: *Library, filter: catalog.Filter, hero: ?usize, query: []const u8) usize {
    return catalog.select(lib.entries, filter, if (query.len > 0) null else hero, query, lib.visible);
}

const SearchEnd = union(enum) { cancel, search, open: usize };

/// The search sheet, with books matching what's typed listed as it changes. Ends by
/// cancelling (what was searched before stays), searching for what's typed (nothing
/// clears the search), or opening a book from the list, by its entry index.
fn typeSearch(a: *app.App, lib: *const Library, q: *search.Query) SearchEnd {
    const kept = q.*;
    var matches: [search_sheet.max_rows + 1]usize = undefined;
    var first = true;
    while (true) {
        const found = catalog.select(lib.entries, .all, null, q.words(), &matches);
        const shown = matches[0..@min(found, search_sheet.max_rows)];
        const page = a.page(a.screen.pixels);
        search_sheet.render(a.ui, page, q.words(), lib.entries, if (q.words().len > 0) shown else &.{}, found > search_sheet.max_rows) catch {};
        // The keyboard never changes, so after the first frame only the top part does
        const bottom: u32 = if (first) a.screen.height else keyboard.top;
        a.showBand(search_sheet.top, bottom - search_sheet.top) catch {};
        first = false;
        const action = a.input.next();
        switch (action) {
            .tap => |t| {
                if (keyboard.hit(t.x, t.y)) |k| switch (k) {
                    .char => |c| q.push(c),
                    .space => q.push(' '),
                    .backspace => q.pop(),
                    .enter => return .search,
                } else switch (search_sheet.hit(t.x, t.y, if (q.words().len > 0) shown.len else 0)) {
                    .cancel => {
                        q.* = kept;
                        return .cancel;
                    },
                    .row => |i| {
                        const entry = shown[i];
                        if (lib.entries[entry].isLocal()) return .{ .open = entry };
                        return .search;
                    },
                    .field, .none => {},
                }
            },
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                q.* = kept;
                return .cancel;
            },
            else => {},
        }
    }
}

pub fn runLibrary(a: *app.App) !void {
    var lib = try loadLibrary(a);
    defer lib.deinit();
    // Started while the Kindle is locked: the "going to lock" event has passed, so
    // show the lock screen now, as if it had just arrived. Otherwise the library
    // would sit under a locked Kindle with touch switched off.
    if (lipc.inScreenSaver() == true) a.input.stashed = .lock;
    var filter: catalog.Filter = .all;
    var order: catalog.Order = .recent;
    var query = search.Query{};
    var message: []const u8 = "";
    var index: usize = 0;
    const buf = a.slots[0].buf;
    a.slots[0].page = -1;
    // Set only for a download started here. Catalog flags can stay stuck, so
    // they must never drive this, and checking must never touch the screen.
    var watch_until: u64 = 0;
    defer a.input.tick_us = 0;

    while (true) {
        // The pager and the keyboard sit along the bottom edge, where the reader ignores
        // a resting thumb. Nothing else is down there, so the library takes every touch.
        // Set each time round, as reading a book turns it back on.
        a.input.grips = false;
        const alloc = lib.arena.allocator();
        catalog.sort(lib.entries, order);
        var hero = catalog.pickHero(lib.entries);
        var count = choose(&lib, filter, hero, query.words());
        index = @min(index, library.pageCount(count) - 1);
        a.quick = lipc.read(a.quick);
        a.input.tick_us = if (nowUs() < watch_until) download_poll_us else 0;
        const r0 = nowUs();
        try library.render(alloc, a.ui, a.page(buf), lib.entries, hero, lib.visible[0..count], index, filter, order, query.words(), message, &a.quick);
        std.debug.print("library render {d} ms\n", .{(nowUs() - r0) / 1000});
        try a.present(buf, .gc16, .full);
        logPage(&lib, index, count);
        message = "";

        browse: while (true) {
            var opening: ?*catalog.Entry = null;
            var acting: ?*catalog.Entry = null;
            var notice: []const u8 = "";
            switch (a.input.next()) {
                .tap => |t| switch (loggedHit(t.x, t.y, index, count, query.words().len > 0)) {
                    .none => continue,
                    .search => switch (typeSearch(a, &lib, &query)) {
                        .cancel => {
                            try a.present(buf, .gc16, .partial);
                            continue;
                        },
                        .search => {
                            count = choose(&lib, filter, hero, query.words());
                            index = 0;
                        },
                        .open => |e| {
                            query = .{};
                            count = choose(&lib, filter, hero, "");
                            index = 0;
                            opening = &lib.entries[e];
                        },
                    },
                    .clear_search => {
                        query = .{};
                        count = choose(&lib, filter, hero, "");
                        index = 0;
                    },
                    .menu => {
                        if (try panel.libraryMenu(a, buf)) return;
                        continue;
                    },
                    .tab => |f| {
                        filter = f;
                        count = choose(&lib, filter, hero, query.words());
                        index = 0;
                    },
                    .sort => {
                        order = order.next();
                        catalog.sort(lib.entries, order);
                        hero = catalog.pickHero(lib.entries);
                        count = choose(&lib, filter, hero, query.words());
                        index = 0;
                    },
                    .next => {
                        if (index + 1 >= library.pageCount(count)) continue;
                        index += 1;
                    },
                    .prev => {
                        if (index == 0) continue;
                        index -= 1;
                    },
                    .hero => {
                        const h = hero orelse continue;
                        a.flash(library.heroRect(a.screen.width));
                        opening = &lib.entries[h];
                    },
                    .hero_dots => acting = &lib.entries[hero orelse continue],
                    .dots => |i| acting = &lib.entries[lib.visible[i]],
                    .book => |i| {
                        const entry = &lib.entries[lib.visible[i]];
                        if (entry.isLocal()) {
                            a.flash(library.bookRect(i, index));
                            opening = entry;
                        } else if (entry.availability == .downloading) {
                            notice = "Still downloading. It will open once it's finished.";
                        } else {
                            notice = "Not on this Kindle yet. Use the three dots to download it.";
                        }
                    },
                },
                .tick => {
                    if (nowUs() >= watch_until) {
                        a.input.tick_us = 0;
                        continue;
                    }
                    catalog_db.exportLibrary();
                    var fresh = loadLibrary(a) catch continue;
                    if (fresh.localCount() == lib.localCount()) {
                        fresh.deinit();
                        continue;
                    }
                    lib.deinit();
                    lib = fresh;
                    watch_until = 0;
                    break :browse;
                },
                .hold, .drag, .drag_end, .unlock => continue,
                .lock => {
                    try lock.lockScreen(a, if (hero) |h| &lib.entries[h] else null);
                    continue;
                },
                .pull => {
                    if (try panel.libraryMenu(a, buf)) return;
                    continue;
                },
                .power, .computer, .stop => return,
            }
            if (opening) |entry| {
                a.input.tick_us = 0;
                const outcome = reader.readBook(a, entry) catch |err| blk: {
                    std.debug.print("could not open book: {s}\n", .{@errorName(err)});
                    message = "This book can't be opened here.";
                    break :blk reader.Outcome.library;
                };
                if (outcome == .quit) return;
                a.slots[0].page = -1;
                break :browse;
            }
            if (acting) |entry| {
                const change = try bookSheet(a, entry, buf);
                if (change != .none) {
                    // Only a download needs watching; nothing else finishes later.
                    if (change == .downloading) watch_until = nowUs() + download_watch_us;
                    catalog_db.exportLibrary();
                    var fresh = loadLibrary(a) catch break :browse;
                    lib.deinit();
                    lib = fresh;
                    fresh = undefined;
                    break :browse;
                }
                continue;
            }
            try library.render(alloc, a.ui, a.page(buf), lib.entries, hero, lib.visible[0..count], index, filter, order, query.words(), notice, &a.quick);
            try a.present(buf, .gc16, .partial);
            logPage(&lib, index, count);
        }
    }
}
