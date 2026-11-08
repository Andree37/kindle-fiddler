//! Go To: the contents sheet over the page. Returns the page to jump to, if any.
const std = @import("std");
const contents = @import("../../ui/contents.zig");
const kfx = @import("../../book/kfx.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, chapters: []const kfx.Chapter) !?usize {
    const page_of = try alloc.alloc(usize, chapters.len);
    for (chapters, page_of) |c, *p| p.* = sess.pageContaining(s.pages, c.para, 0);
    const reading = contents.current(chapters, s.pages[s.current].para);
    var list_page: usize = if (reading) |r| contents.listPageOf(r) else 0;
    const background = try s.ensure(s.current, s.current);
    while (true) {
        @memcpy(a.overlay, background);
        // The toolbar stays drawn above, from what's on screen now.
        @memcpy(a.overlay[0 .. contents.top * a.screen.stride], a.screen.pixels[0 .. contents.top * a.screen.stride]);
        try contents.render(a.ui, a.page(a.overlay), chapters, page_of, reading, list_page);
        @memcpy(a.screen.pixels, a.overlay);
        try a.showBand(contents.top, a.screen.height - contents.top);
        const choice = while (true) {
            const action = a.input.next();
            switch (action) {
                .tap => |t| switch (contents.hit(t.x, t.y, list_page, chapters.len)) {
                    .none => continue,
                    else => |h| break h,
                },
                .lock, .power, .idle, .stop => {
                    a.input.stashed = action;
                    return null;
                },
                else => {},
            }
        };
        switch (choice) {
            .close, .none => return null,
            .chapter => |i| {
                std.debug.print("goto chapter {d} of {d}: page {d}\n", .{ i + 1, chapters.len, page_of[i] + 1 });
                return page_of[i];
            },
            .prev => list_page -|= 1,
            .next => list_page = @min(list_page + 1, contents.pageCount(chapters.len) - 1),
        }
    }
}
