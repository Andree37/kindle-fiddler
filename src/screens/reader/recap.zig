//! "Previously on": back in a book after days away, a sheet over the page with who's
//! been around lately and the words just before it, to find the thread again. Shown
//! on its own after a few days, and from the reader's menu any time.
const std = @import("std");
const characters = @import("../../model/characters.zig");
const recap = @import("../../model/recap.zig");
const goto_ui = @import("../../ui/goto.zig");
const text_sheet = @import("../../ui/text_sheet.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// How much of what came before to show: about seven lines, so it always fits
/// whole. Cut short, it would lose the lines nearest the page, which matter most.
const before_bytes = 460;
/// "Lately" means the last this many paragraphs.
const lately_paragraphs = 120;

/// Shows a text sheet over the screen until a tap, then puts the screen back.
pub fn showSheet(a: *app.App, title: []const u8, subtitle: []const u8, blocks: []const text_sheet.Block) !void {
    @memcpy(a.overlay, a.screen.pixels);
    try text_sheet.render(a.ui, a.page(a.screen.pixels), title, subtitle, blocks);
    try a.showBand(0, a.screen.height);
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tap => break,
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                break;
            },
            else => {},
        }
    }
    @memcpy(a.screen.pixels, a.overlay);
    try a.showBand(0, a.screen.height);
}

/// "Elizabeth, Mr. Darcy and Jane".
fn joinNames(alloc: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(alloc, if (i + 1 == names.len) " and " else ", ");
        try out.appendSlice(alloc, n);
    }
    return out.items;
}

/// "4 days", "3 weeks", "2 months".
fn awayFor(buf: []u8, seconds: u64) []const u8 {
    const days = seconds / 86400;
    const n, const unit = if (days < 14) .{ days, "day" } else if (days < 60) .{ days / 7, "week" } else .{ days / 30, "month" };
    return std.fmt.bufPrint(buf, "{d} {s}{s} away", .{ n, unit, if (n == 1) "" else "s" }) catch "";
}

/// The recap for the page on screen. `away_s`, when known, says how long it's been.
pub fn show(a: *app.App, s: *const sess.Session, alloc: std.mem.Allocator, away_s: ?u64) !void {
    const here = s.pages[s.current];
    var blocks: std.ArrayList(text_sheet.Block) = .empty;

    var cast_buf: [40]characters.Character = undefined;
    const cast = try characters.find(alloc, s.paragraphs, here.para, &cast_buf);
    var who_buf: [4]usize = undefined;
    const who = recap.lately(s.paragraphs, cast, here.para, lately_paragraphs, &who_buf);
    if (who.len > 0) {
        var names: [4][]const u8 = undefined;
        for (who, 0..) |i, j| names[j] = cast[i].name;
        try blocks.append(alloc, .{ .kind = .heading, .text = "Lately" });
        try blocks.append(alloc, .{ .kind = .text, .text = try joinNames(alloc, names[0..who.len]) });
    }

    var span_buf: [12]recap.Span = undefined;
    const spans = recap.before(s.paragraphs, here, before_bytes, &span_buf);
    if (spans.len > 0) {
        try blocks.append(alloc, .{ .kind = .heading, .text = "Just before this page" });
        for (spans) |span| try blocks.append(alloc, .{ .kind = .text, .text = recap.text(s.paragraphs, span) });
    } else {
        try blocks.append(alloc, .{ .kind = .text, .text = "This is where the book begins." });
    }

    // The chapter, and the time away when it's why the recap is showing
    const chapter = if (goto_ui.current(s.chapters, here.para)) |i| s.chapters[i].title else "";
    var away_buf: [32]u8 = undefined;
    const away = if (away_s) |sec| awayFor(&away_buf, sec) else "";
    const subtitle = if (chapter.len > 0 and away.len > 0)
        try std.fmt.allocPrint(alloc, "{s}  \u{b7}  {s}", .{ chapter, away })
    else if (chapter.len > 0) chapter else away;
    std.debug.print("recap: {d} names, {d} passages\n", .{ who.len, spans.len });
    try showSheet(a, "Previously", subtitle, blocks.items);
}

test "time away reads naturally" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3 days away", awayFor(&buf, 3 * 86400 + 100));
    try std.testing.expectEqualStrings("1 day away", awayFor(&buf, 86400));
    try std.testing.expectEqualStrings("3 weeks away", awayFor(&buf, 21 * 86400));
    try std.testing.expectEqualStrings("4 months away", awayFor(&buf, 125 * 86400));
}

test "names join with commas and a final and" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Ann", try joinNames(arena.allocator(), &.{"Ann"}));
    try std.testing.expectEqualStrings("Ann and Bob", try joinNames(arena.allocator(), &.{ "Ann", "Bob" }));
    try std.testing.expectEqualStrings("Ann, Bob and Cat", try joinNames(arena.allocator(), &.{ "Ann", "Bob", "Cat" }));
}
