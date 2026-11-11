//! Notes the battery level whenever it changes, for how long it will last. Read from
//! sysfs, so it costs a file read, not a program. The log keeps its newest part only.
const std = @import("std");
const battery = @import("../model/battery.zig");
const state = @import("../linux/state.zig");
const os = @import("../linux/os.zig");
const linux = std.os.linux;

const capacity_path = "/sys/class/power_supply/bd71827_bat/capacity";
const plugged_path = "/sys/class/power_supply/bd71827_ac/online";
/// Past this the log is cut to its newest half: weeks of changes either way.
const max_bytes = 48 * 1024;

/// The battery now, or null off a Kindle.
pub fn now() ?battery.Sample {
    var buf: [16]u8 = undefined;
    const level = std.fmt.parseInt(u32, std.mem.trim(u8, state.readSmall(capacity_path, &buf), " \n"), 10) catch return null;
    const plugged = std.mem.startsWith(u8, state.readSmall(plugged_path, &buf), "1");
    return .{ .time = os.unixTime(), .level = level, .plugged = plugged };
}

/// Adds the battery to the log at `path` if it changed since `last`, which it updates.
pub fn note(path: [*:0]const u8, last: *?battery.Sample) void {
    const s = now() orelse return;
    if (last.*) |l| {
        if (l.level == s.level and l.plugged == s.plugged) return;
    }
    last.* = s;
    var line_buf: [40]u8 = undefined;
    const line = battery.formatLine(&line_buf, s);
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (os.failed(rc)) return;
    const fd: i32 = @intCast(rc);
    _ = linux.write(fd, line.ptr, line.len);
    var size: linux.off_t = 0;
    const big = !os.failed(linux.llseek(fd, 0, &size, linux.SEEK.END)) and size > max_bytes;
    _ = linux.close(fd);
    if (big) trim(path);
}

/// Keeps the newest half of the log, from a line start.
fn trim(path: [*:0]const u8) void {
    var buf: [max_bytes + 4096]u8 = undefined;
    const all = state.readSmall(path, &buf);
    const cut = all.len / 2;
    const start = (std.mem.indexOfScalarPos(u8, all, cut, '\n') orelse return) + 1;
    state.writeSmall(path, all[start..]);
}

/// The samples in the log, oldest first, as many as `out` holds (the newest).
pub fn load(path: [*:0]const u8, out: []battery.Sample) []battery.Sample {
    var buf: [max_bytes + 4096]u8 = undefined;
    const all = state.readSmall(path, &buf);
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, all, '\n');
    while (lines.next()) |line| {
        const s = battery.parseLine(line) orelse continue;
        if (n == out.len) {
            std.mem.copyForwards(battery.Sample, out[0 .. n - 1], out[1..n]);
            n -= 1;
        }
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}
