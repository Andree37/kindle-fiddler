//! Small helpers over raw Linux syscalls, shared across the app.
const std = @import("std");
const linux = std.os.linux;

/// Raw syscalls return errors as values in the top 4096 of the range.
pub fn failed(rc: usize) bool {
    return rc > std.math.maxInt(usize) - 4096;
}

/// Microseconds on the monotonic clock, which stops while the Kindle sleeps.
pub fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Seconds since 1970, for dates people see and that survive a restart.
pub fn unixTime() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn sleepMs(ms: u64) void {
    const wait = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&wait, null);
}

test "error codes are told from results" {
    try std.testing.expect(failed(@bitCast(@as(isize, -2))));
    try std.testing.expect(!failed(3));
}
