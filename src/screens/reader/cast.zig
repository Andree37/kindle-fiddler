//! The characters met so far, most mentioned first, under the toolbar like Go To.
//! Tapping one shows the sentences they were last seen in, all before the reader's
//! place, so nothing ahead is given away.
const std = @import("std");
const characters = @import("../../model/characters.zig");
const recap = @import("../../model/recap.zig");
const goto_ui = @import("../../ui/goto.zig");
const text_sheet = @import("../../ui/text_sheet.zig");
const app = @import("../../app.zig");
const recap_view = @import("recap.zig");
const sess = @import("session.zig");
const os = @import("../../linux/os.zig");

const most = 60;
const seen_count = 3;

pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !void {
    const until = s.pages[s.current].para;
    var cast_buf: [most]characters.Character = undefined;
    const t0 = os.nowUs();
    const cast = try characters.find(alloc, s.paragraphs, until, &cast_buf);
    const rows = try alloc.alloc(goto_ui.Row, cast.len);
    for (cast, rows) |c, *r| r.* = .{ .label = c.name, .page = 0, .note = "" };
    std.debug.print("characters: {d} so far, found in {d} ms\n", .{ cast.len, (os.nowUs() - t0) / 1000 });

    var list_page: usize = 0;
    var stale = true; // The list needs drawing
    const background = try s.ensure(s.current, s.current);
    while (true) {
        if (stale) {
            @memcpy(a.overlay, background);
            // The toolbar stays drawn above, from what's on screen now
            @memcpy(a.overlay[0 .. goto_ui.top * a.screen.stride], a.screen.pixels[0 .. goto_ui.top * a.screen.stride]);
            try goto_ui.renderTitled(a.ui, a.page(a.overlay), "Characters", "So far", rows, list_page, "No characters met yet.");
            @memcpy(a.screen.pixels, a.overlay);
            try a.showBand(goto_ui.top, a.screen.height - goto_ui.top);
        }
        stale = true;
        const choice = while (true) {
            const action = a.input.next();
            switch (action) {
                .tap => |t| switch (goto_ui.hit(t.x, t.y, list_page, rows.len)) {
                    .none, .tab => continue,
                    else => |h| break h,
                },
                .lock, .power, .computer, .stop => {
                    a.input.stashed = action;
                    return;
                },
                else => {},
            }
        };
        switch (choice) {
            .close, .none, .tab => return,
            .row => |i| {
                try person(a, s, alloc, cast[i], until);
                if (a.input.stashed != null) return;
                stale = false; // The sheet put the list back
            },
            .prev => list_page -|= 1,
            .next => list_page = @min(list_page + 1, goto_ui.pageCount(rows.len) - 1),
        }
    }
}

/// One character's sheet: how often they've come up, and where they were last seen.
fn person(a: *app.App, s: *const sess.Session, alloc: std.mem.Allocator, c: characters.Character, until: usize) !void {
    var blocks: std.ArrayList(text_sheet.Block) = .empty;
    var seen_buf: [seen_count]recap.Span = undefined;
    const seen = recap.lastSeen(s.paragraphs, c, until, &seen_buf);
    if (seen.len > 0) try blocks.append(alloc, .{ .kind = .heading, .text = "Last seen" });
    for (seen) |span| {
        const page = sess.pageContaining(s.pages, span.para, span.start);
        try blocks.append(alloc, .{ .kind = .note, .text = try std.fmt.allocPrint(alloc, "Page {d}", .{page + 1}) });
        try blocks.append(alloc, .{ .kind = .text, .text = recap.text(s.paragraphs, span) });
    }
    const first = sess.pageContaining(s.pages, c.first_para, 0);
    const subtitle = try std.fmt.allocPrint(alloc, "Mentioned {d} times  \u{b7}  first on page {d}", .{ c.mentions, first + 1 });
    try recap_view.showSheet(a, c.name, subtitle, blocks.items);
}
