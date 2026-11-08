//! Go to page: type a page number, jump there. Returns the page index, if any.
const std = @import("std");
const goto = @import("../../ui/goto.zig");
const keyboard = @import("../../ui/keyboard.zig");
const field = @import("../../ui/field.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// A typed page number as a page index, or null when it isn't a page of this book.
pub fn pageIndex(typed: []const u8, pages: usize) ?usize {
    const n = std.fmt.parseInt(usize, typed, 10) catch return null;
    return if (n >= 1 and n <= pages) n - 1 else null;
}

pub fn run(a: *app.App, s: *sess.Session) !?usize {
    var digits: [6]u8 = undefined;
    var len: usize = 0;
    var placeholder_buf: [48]u8 = undefined;
    const placeholder = std.fmt.bufPrint(&placeholder_buf, "Page, from 1 to {d}", .{s.pages.len}) catch "Page";
    var note: []const u8 = "";
    var whole = true; // Draw the keyboard and what's under the field the first time
    const background = try s.ensure(s.current, s.current);
    while (true) {
        @memcpy(a.overlay, a.screen.pixels);
        if (whole) @memcpy(a.overlay[goto.top * a.screen.stride ..], background[goto.top * a.screen.stride ..]);
        const page = a.page(a.overlay);
        try field.render(a.ui, page, digits[0..len], placeholder, true, note);
        if (whole) try keyboard.render(a.ui, page);
        @memcpy(a.screen.pixels, a.overlay);
        try a.showBand(goto.top, a.screen.height - goto.top);
        whole = false;

        const action = a.input.next();
        switch (action) {
            .tap => |t| {
                if (t.y < goto.top) return null;
                note = "";
                switch (keyboard.hit(t.x, t.y) orelse continue) {
                    .char => |c| {
                        // Only digits mean anything here; letters are ignored.
                        if (std.ascii.isDigit(c) and len < digits.len) {
                            digits[len] = c;
                            len += 1;
                        }
                    },
                    .backspace => len -|= 1,
                    .space => {},
                    .enter => {
                        if (pageIndex(digits[0..len], s.pages.len)) |index| return index;
                        note = "No such page";
                    },
                }
            },
            .lock, .power, .idle, .stop => {
                a.input.stashed = action;
                return null;
            },
            else => {},
        }
    }
}

test "typed numbers become pages of this book" {
    try std.testing.expectEqual(@as(usize, 0), pageIndex("1", 760).?);
    try std.testing.expectEqual(@as(usize, 759), pageIndex("760", 760).?);
    try std.testing.expect(pageIndex("761", 760) == null);
    try std.testing.expect(pageIndex("0", 760) == null);
    try std.testing.expect(pageIndex("", 760) == null);
}
