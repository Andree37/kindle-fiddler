//! Checks that stay on in every build mode.
//!
//! Zig's own `std.debug.assert` is not checked in ReleaseFast, the mode noface ships
//! in: the compiler assumes it holds, so a wrong assumption turns into silent memory
//! corruption. These checks always run. When one fails, noface stops with a message
//! saying what broke, and device/noface.sh puts the Kindle back to stock.
//!
//! They state our own invariants. Data from outside (book files, the catalog,
//! settings, the annotation database) is never checked this way: it's handled as an
//! error, because a bad book must not stop the reader.
const std = @import("std");

/// Stops noface when `ok` is false. `what` says what should have been true.
pub inline fn that(ok: bool, comptime what: []const u8) void {
    if (!ok) failed(what);
}

/// Like `that`, with values in the message: `check.thatf(i < n, "page {d} of {d}", .{ i, n })`.
pub inline fn thatf(ok: bool, comptime what: []const u8, args: anytype) void {
    if (!ok) failedf(what, args);
}

fn failed(comptime what: []const u8) noreturn {
    @branchHint(.cold);
    std.debug.panic("check failed: " ++ what, .{});
}

fn failedf(comptime what: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    std.debug.panic("check failed: " ++ what, args);
}

test "checks that hold do nothing" {
    that(true, "never shown");
    thatf(1 < 2, "never shown {d}", .{1});
}
