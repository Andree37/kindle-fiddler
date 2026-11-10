//! Reading stats, opened from the library. Any tap goes back.
const std = @import("std");
const stats_ui = @import("../ui/stats.zig");
const catalog = @import("../model/catalog.zig");
const journal = @import("../model/journal.zig");
const app = @import("../app.zig");

/// What the screen shows, from the journal, the reading speed and the library.
pub fn summarize(a: *const app.App, entries: []const catalog.Entry) stats_ui.Summary {
    const j = &a.journal;
    const today = a.today();
    var s = stats_ui.Summary{
        .today = j.get(today).seconds,
        .week = j.secondsOver(today, 7),
        .streak = j.streak(today),
        .first_weekday = journal.weekday(today - 6),
    };
    for (&s.last7, 0..) |*d, i| d.* = j.get(today - 6 + @as(i32, @intCast(i))).seconds;
    const year_start = journal.yearStart(today);
    const year = j.since(year_start, today);
    s.year = @intCast((std.time.epoch.EpochDay{ .day = @intCast(today) }).calculateYearDay().year);
    s.year_finished = year.finished;
    s.year_seconds = year.seconds;
    if (a.speed.known()) s.wpm = @intFromFloat(@round(a.speed.wpm()));
    for (entries) |e| {
        s.books += 1;
        if (e.isRead()) s.finished += 1;
        if (e.inProgress()) s.in_progress += 1;
    }
    return s;
}

/// Shows the stats over `buf`'s screen until a tap. Passes on a lock or quit.
pub fn run(a: *app.App, entries: []const catalog.Entry) !void {
    try stats_ui.render(a.ui, a.page(a.screen.pixels), summarize(a, entries));
    try a.showBand(stats_ui_top, a.screen.height - stats_ui_top);
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tap => return,
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                return;
            },
            else => {},
        }
    }
}

const stats_ui_top = 96; // Under the status strip, which stays
