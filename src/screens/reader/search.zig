//! Search: type a word, see where it appears, and jump there. Returns the page to
//! go to, if any. The last query stays for the next search in this book.
const std = @import("std");
const goto = @import("../../ui/goto.zig");
const keyboard = @import("../../ui/keyboard.zig");
const field = @import("../../ui/field.zig");
const search = @import("../../model/search.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

const max_results = 500;
const snippet_bytes = 160;

pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !?usize {
    var typing = true;
    var list_page: usize = 0;
    var results: []const goto.Row = &.{};
    const background = try s.ensure(s.current, s.current);
    var whole = true; // Redraw everything below the toolbar, not just the field
    while (true) {
        @memcpy(a.overlay, a.screen.pixels);
        if (whole) @memcpy(a.overlay[goto.top * a.screen.stride ..], background[goto.top * a.screen.stride ..]);
        const page = a.page(a.overlay);
        var count_buf: [32]u8 = undefined;
        const count: []const u8 = if (typing) "" else if (results.len >= max_results) "500+ results" else std.fmt.bufPrint(&count_buf, "{d} result{s}", .{ results.len, if (results.len == 1) "" else "s" }) catch "";
        try field.render(a.ui, page, s.query.slice(), "Search this book", typing, count);
        if (typing) {
            try keyboard.render(a.ui, page);
        } else if (whole) {
            try goto.renderList(a.ui, page, results, null, list_page, "No matches in this book.");
        }
        @memcpy(a.screen.pixels, a.overlay);
        try a.showBand(goto.top, a.screen.height - goto.top);
        whole = false;

        const action = a.input.next();
        switch (action) {
            .tap => |t| {
                if (t.y < goto.top) return null;
                if (typing) {
                    const k = keyboard.hit(t.x, t.y) orelse continue;
                    switch (k) {
                        .char => |c| s.query.push(c),
                        .space => s.query.push(' '),
                        .backspace => s.query.pop(),
                        .enter => {
                            const q = std.mem.trim(u8, s.query.slice(), " ");
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
                if (field.inField(t.y)) {
                    typing = true;
                    whole = true;
                    continue;
                }
                switch (goto.hit(t.x, t.y, list_page, results.len)) {
                    .row => |i| return results[i].page,
                    .prev => list_page -|= 1,
                    .next => list_page = @min(list_page + 1, goto.pageCount(results.len) - 1),
                    .close => return null,
                    .none, .tab => continue,
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
