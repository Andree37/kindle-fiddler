//! How long the battery will last, from how fast it has drained lately. noface notes the
//! level each time it changes; the time between two notes, both unplugged and the level
//! not risen, is real use (reading, and asleep in between). Plain data, no drawing.
const std = @import("std");

pub const Sample = struct { time: u64, level: u32, plugged: bool };

/// Drain from these days back counts: recent enough to follow how it's used now.
pub const window_s: u64 = 14 * 86400;
/// Less than this to go on, and the estimate would be noise.
const min_span_s: u64 = 12 * 3600;
const min_drop = 3;

/// "1793990000 87 u": time, level, plugged ("p") or unplugged ("u").
pub fn parseLine(line: []const u8) ?Sample {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const time = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const level = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const plug = it.next() orelse return null;
    if (level > 100) return null;
    return .{ .time = time, .level = level, .plugged = std.mem.eql(u8, plug, "p") };
}

pub fn formatLine(buf: []u8, s: Sample) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {d} {s}\n", .{ s.time, s.level, if (s.plugged) "p" else "u" }) catch "";
}

/// Seconds the battery has left at `level`, at the drain seen in `log` (oldest first).
/// Null while there isn't enough unplugged use to tell.
pub fn secondsLeft(log: []const Sample, now: u64, level: u32) ?u64 {
    var drop: u64 = 0;
    var span: u64 = 0;
    if (log.len < 2) return null;
    for (log[0 .. log.len - 1], log[1..]) |a, b| {
        if (b.time + window_s < now or b.time <= a.time) continue;
        if (a.plugged or b.plugged or b.level > a.level) continue; // Charged in between
        drop += a.level - b.level;
        span += b.time - a.time;
    }
    if (span < min_span_s or drop < min_drop) return null;
    return level * span / drop;
}

/// "About 2 weeks", "About 5 days", "About 20 hours".
pub fn describe(buf: []u8, seconds: u64) []const u8 {
    const hours = seconds / 3600;
    const days = (seconds + 43200) / 86400;
    const weeks = (seconds + 3 * 86400) / (7 * 86400);
    if (hours < 36) return std.fmt.bufPrint(buf, "About {d} hour{s}", .{ @max(hours, 1), if (hours == 1) "" else "s" }) catch "";
    if (days < 14) return std.fmt.bufPrint(buf, "About {d} days", .{days}) catch "";
    return std.fmt.bufPrint(buf, "About {d} weeks", .{weeks}) catch "";
}

test "lines read back as written" {
    var buf: [40]u8 = undefined;
    const s = Sample{ .time = 1793990000, .level = 87, .plugged = false };
    const line = formatLine(&buf, s);
    try std.testing.expectEqualStrings("1793990000 87 u\n", line);
    try std.testing.expectEqual(s, parseLine(std.mem.trimEnd(u8, line, "\n")).?);
    try std.testing.expect(parseLine("12 300 u") == null);
    try std.testing.expect(parseLine("junk") == null);
}

test "drain counts only unplugged time, and charging breaks it" {
    const d = 86400;
    const log = [_]Sample{
        .{ .time = 0, .level = 100, .plugged = false },
        .{ .time = d, .level = 95, .plugged = false }, // 5% a day
        .{ .time = d + 3600, .level = 96, .plugged = true }, // Plugged: not counted
        .{ .time = 2 * d, .level = 100, .plugged = false },
        .{ .time = 3 * d, .level = 95, .plugged = false }, // 5% a day again
    };
    // 10% over 2 days: at 95%, 19 days left
    try std.testing.expectEqual(@as(u64, 19 * d), secondsLeft(&log, 3 * d, 95).?);
}

test "too little to go on says nothing" {
    const log = [_]Sample{
        .{ .time = 0, .level = 100, .plugged = false },
        .{ .time = 3600, .level = 99, .plugged = false },
    };
    try std.testing.expect(secondsLeft(&log, 3600, 99) == null);
    try std.testing.expect(secondsLeft(log[0..1], 0, 100) == null);
}

test "old drain falls out of the window" {
    const d = 86400;
    const log = [_]Sample{
        .{ .time = 0, .level = 100, .plugged = false },
        .{ .time = d, .level = 50, .plugged = false }, // A bad day, a month ago
        .{ .time = 30 * d, .level = 100, .plugged = false },
        .{ .time = 32 * d, .level = 90, .plugged = false },
    };
    try std.testing.expectEqual(@as(u64, 18 * d), secondsLeft(&log, 32 * d, 90).?);
}

test "times read naturally" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("About 20 hours", describe(&buf, 20 * 3600));
    try std.testing.expectEqualStrings("About 5 days", describe(&buf, 5 * 86400));
    try std.testing.expectEqualStrings("About 3 weeks", describe(&buf, 21 * 86400));
}
