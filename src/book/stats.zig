//! Reading statistics: how fast this reader reads, and so how long is left.
//! Speed is in bytes of text per second, learned from real page turns.
const std = @import("std");

const min_page_seconds = 3; // Quicker than this is flicking past, not reading
pub const max_page_seconds = 300; // Longer than this, the reader stepped away: not reading

/// Text read and time spent reading it, summed over every book.
pub const Speed = struct {
    bytes: u64 = 0,
    seconds: u64 = 0,

    /// Counts one page read forward. Flicks and pages left open are ignored.
    pub fn record(s: *Speed, bytes: u64, seconds: u64) void {
        if (seconds < min_page_seconds or seconds > max_page_seconds or bytes == 0) return;
        s.bytes += bytes;
        s.seconds += seconds;
    }

    /// Enough reading to give honest estimates: five minutes over a few pages.
    pub fn known(s: Speed) bool {
        return s.seconds >= 300 and s.bytes >= 3000;
    }

    /// Minutes to read `bytes` more, rounded up. Null until the speed is known.
    pub fn minutesFor(s: Speed, bytes: u64) ?u64 {
        if (!s.known()) return null;
        const seconds = bytes * s.seconds / s.bytes;
        return (seconds + 59) / 60;
    }
};

/// Time counted toward a book: the time on a page, unless it was left open.
pub fn countedSeconds(seconds: u64) u64 {
    return if (seconds > max_page_seconds) 0 else seconds;
}

/// "12 min", "1 h 5 min", "3 h".
pub fn formatMinutes(buf: []u8, minutes: u64) []const u8 {
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d} min", .{@max(minutes, 1)}) catch "";
    const h = minutes / 60;
    const m = minutes % 60;
    if (m == 0) return std.fmt.bufPrint(buf, "{d} h", .{h}) catch "";
    return std.fmt.bufPrint(buf, "{d} h {d} min", .{ h, m }) catch "";
}

pub fn parse(content: []const u8) Speed {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    const bytes = std.fmt.parseInt(u64, it.next() orelse return .{}, 10) catch return .{};
    const seconds = std.fmt.parseInt(u64, it.next() orelse return .{}, 10) catch return .{};
    return .{ .bytes = bytes, .seconds = seconds };
}

pub fn format(buf: []u8, s: Speed) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {d}\n", .{ s.bytes, s.seconds }) catch "";
}

test "speed learns from real reading only" {
    var s = Speed{};
    s.record(1000, 1); // A flick
    try std.testing.expectEqual(@as(u64, 0), s.bytes);
    s.record(1500, 9999); // Stepped away: not counted at all
    try std.testing.expectEqual(@as(u64, 0), s.seconds);
    s.record(1500, 180);
    s.record(1500, 180);
    try std.testing.expectEqual(@as(u64, 360), s.seconds);
    try std.testing.expect(s.known());
    // 3000 bytes in 360 s: 6000 more takes 720 s, 12 minutes.
    try std.testing.expectEqual(@as(u64, 12), s.minutesFor(6000).?);
    try std.testing.expectEqual(@as(u64, 0), countedSeconds(9999));
    try std.testing.expect((Speed{}).minutesFor(100) == null);
}

test "durations read naturally" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12 min", formatMinutes(&buf, 12));
    try std.testing.expectEqualStrings("1 min", formatMinutes(&buf, 0));
    try std.testing.expectEqualStrings("1 h 5 min", formatMinutes(&buf, 65));
    try std.testing.expectEqualStrings("3 h", formatMinutes(&buf, 180));
}

test "speed survives a save" {
    var buf: [48]u8 = undefined;
    const s = Speed{ .bytes = 123456, .seconds = 789 };
    try std.testing.expectEqual(s, parse(format(&buf, s)));
    try std.testing.expectEqual(Speed{}, parse("garbage"));
}
