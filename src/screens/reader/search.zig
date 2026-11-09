//! Search: type a word, see where it appears, and jump there. Returns the page to
//! go to, if any. The last query stays for the next search in this book.
const std = @import("std");
const goto = @import("../../ui/goto.zig");
const keyboard = @import("../../ui/keyboard.zig");
const search_sheet = @import("../../ui/search_sheet.zig");
const style = @import("../../ui/style.zig");
const toolbar = @import("../../ui/toolbar.zig");
const search = @import("../../model/search.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

const max_results = 500;
const snippet_bytes = 160;

pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !?usize {
    var typing = true;
    var list_page: usize = 0;
    var results: []const goto.Row = &.{};
    var whole = true; // Redraw the keyboard or the list, not just the bar
    while (true) {
        const page = a.page(a.screen.pixels);
        try search_sheet.renderBar(a.ui, page, toolbar.status_row, s.query.slice(), "Search this book", .search);
        if (typing) {
            if (whole) {
                page.fillRect(0, search_sheet.content_top, page.width, keyboard.top - search_sheet.content_top, 0xff);
                try keyboard.render(a.ui, page);
            }
        } else if (whole) {
            page.fillRect(0, search_sheet.content_top, page.width, goto.list_top - search_sheet.content_top, 0xff);
            var count_buf: [32]u8 = undefined;
            const count = if (results.len >= max_results) "500+ results" else std.fmt.bufPrint(&count_buf, "{d} result{s}", .{ results.len, if (results.len == 1) "" else "s" }) catch "";
            try a.ui.caption.draw(page, style.margin, search_sheet.content_top + 56, count);
            try goto.renderList(a.ui, page, results, null, list_page, "No matches in this book.");
        }
        const bottom: u32 = if (whole) a.screen.height else search_sheet.content_top;
        try a.showBand(toolbar.status_row, bottom - toolbar.status_row);
        whole = false;

        const action = a.input.next();
        switch (action) {
            .tap => |t| {
                if (search_sheet.barHit(t.x, t.y)) |h| {
                    if (h == .cancel) return null;
                    if (!typing) {
                        typing = true;
                        whole = true;
                    }
                    continue;
                }
                if (t.y < search_sheet.top) return null;
                if (typing) {
                    const k = keyboard.hit(t.x, t.y) orelse continue;
                    switch (k) {
                        .char => |c| s.query.push(c),
                        .space => s.query.push(' '),
                        .backspace => s.query.pop(),
                        .enter => {
                            const q = s.query.words();
                            if (q.len == 0) continue;
                            results = try find(alloc, s, q);
                            std.debug.print("search: {d} results\n", .{results.len});
                            typing = false;
                            list_page = 0;
                            whole = true;
                        },
                    }
                    continue;
                }
                switch (goto.hit(t.x, t.y, list_page, results.len)) {
                    .row => |i| return results[i].page,
                    .prev => list_page -|= 1,
                    .next => list_page = @min(list_page + 1, goto.pageCount(results.len) - 1),
                    .close, .none, .tab => continue,
                }
                whole = true;
            },
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                return null;
            },
            else => {},
        }
    }
}

fn find(alloc: std.mem.Allocator, s: *const sess.Session, query: []const u8) ![]const goto.Row {
    const matches = try search.find(alloc, s.paragraphs, query, max_results);
    const rows = try alloc.alloc(goto.Row, matches.len);
    for (matches, rows) |m, *r| r.* = .{
        .label = search.snippet(s.paragraphs[m.para].text, m.byte, snippet_bytes),
        .page = sess.pageContaining(s.pages, m.para, m.byte),
    };
    return rows;
}
