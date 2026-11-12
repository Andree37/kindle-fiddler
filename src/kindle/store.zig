//! Amazon's store actions on a book: download, remove from the device, mark as read.
const std = @import("std");
const process = @import("../sys/process.zig");
const safe = @import("safe.zig");

fn readNowAction(prop: []const u8, comptime fields: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    const command = std.fmt.bufPrintSentinel(
        &buf,
        "echo '{{ " ++ fields ++ " }}' | /usr/bin/lipc-hash-prop com.lab126.readnow {s}",
        args ++ .{prop},
        0,
    ) catch return;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    var out: [64]u8 = undefined;
    _ = process.run(&argv, &out);
}

/// Queues a cloud book for download.
pub fn downloadBook(key: []const u8, kind: []const u8) void {
    if (!safe.safeId(key) or !safe.safeId(kind)) return;
    readNowAction("kppDownloadAction", "kppItems = \"{s},{s}\"", .{ key, kind });
}

/// Removes the local copy. Never sets kppFrom: "cloud" there revokes samples.
pub fn removeDownload(key: []const u8, kind: []const u8) void {
    if (!safe.safeId(key) or !safe.safeId(kind)) return;
    readNowAction("kppDeleteItemAction", "kppCdeKey = \"{s}\", kppCdeType = \"{s}\"", .{ key, kind });
}

pub fn markRead(key: []const u8, kind: []const u8, read_it: bool) void {
    if (!safe.safeId(key) or !safe.safeId(kind)) return;
    const value = if (read_it) "actionRead" else "actionUnread";
    readNowAction("kppMarkAsReadAction", "kppCdeKey = \"{s}\", kppCdeType = \"{s}\", kppMAR = \"{s}\"", .{ key, kind, value });
}
