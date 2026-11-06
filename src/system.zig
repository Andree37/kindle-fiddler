//! Device settings, changed through Amazon's lipc command line tools.
const std = @import("std");
const linux = std.os.linux;

const lipc_get: [*:0]const u8 = "/usr/bin/lipc-get-prop";
const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

pub const max_brightness = 24;
pub const brightness_step = 2;

pub const Quick = struct {
    brightness: u32 = 0,
    airplane: bool = false,
    battery: u32 = 0,
    clock: [40]u8 = undefined,
    clock_len: usize = 0,

    pub fn clockText(q: *const Quick) []const u8 {
        return q.clock[0..q.clock_len];
    }
};

fn failed(rc: usize) bool {
    return rc > std.math.maxInt(usize) - 4096;
}

/// Runs a program and returns how many bytes of its output landed in `out`.
fn run(argv: [*:null]const ?[*:0]const u8, out: []u8) ?usize {
    var fds: [2]i32 = undefined;
    if (failed(linux.pipe(&fds))) return null;
    const pid = linux.fork();
    if (failed(pid)) return null;
    if (pid == 0) {
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0].?, argv, &envp);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    var total: usize = 0;
    while (total < out.len) {
        const n = linux.read(fds[0], out[total..].ptr, out.len - total);
        if (failed(n) or n == 0) break;
        total += n;
    }
    _ = linux.close(fds[0]);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return total;
}

pub fn parseInt(output: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, output, " \n"), 10) catch null;
}

fn get(service: [*:0]const u8, prop: [*:0]const u8) ?u32 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, service, prop };
    var buf: [32]u8 = undefined;
    const n = run(&argv, &buf) orelse return null;
    return parseInt(buf[0..n]);
}

fn set(service: [*:0]const u8, prop: [*:0]const u8, value: u32) void {
    var text: [16]u8 = undefined;
    const arg = std.fmt.bufPrintSentinel(&text, "{d}", .{value}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ lipc_set, service, prop, arg };
    var buf: [32]u8 = undefined;
    _ = run(&argv, &buf);
}

pub fn read() Quick {
    var q = Quick{
        .brightness = get("com.lab126.powerd", "flIntensity") orelse 0,
        .airplane = (get("com.lab126.cmd", "wirelessEnable") orelse 1) == 0,
        .battery = get("com.lab126.powerd", "battLevel") orelse 0,
    };
    const argv = [_:null]?[*:0]const u8{ "/bin/date", "+%H:%M - %d %b %Y" };
    if (run(&argv, &q.clock)) |n| q.clock_len = std.mem.trimEnd(u8, q.clock[0..n], "\n").len;
    return q;
}

pub fn openSettings() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "com.lab126.appmgrd", "start", "app://com.lab126.booklet.settings" };
    var buf: [32]u8 = undefined;
    _ = run(&argv, &buf);
}

pub fn setBrightness(level: u32) void {
    set("com.lab126.powerd", "flIntensity", level);
}

pub fn setAirplane(on: bool) void {
    set("com.lab126.cmd", "wirelessEnable", if (on) 0 else 1);
}

/// Steps brightness, stopping at both ends.
pub fn stepBrightness(level: u32, up: bool) u32 {
    if (up) return @min(level + brightness_step, max_brightness);
    return level -| brightness_step;
}

test "tool output parses" {
    try std.testing.expectEqual(@as(u32, 21), parseInt("21\n").?);
    try std.testing.expect(parseInt("failed\n") == null);
}

test "brightness stops at both ends" {
    try std.testing.expectEqual(@as(u32, 24), stepBrightness(23, true));
    try std.testing.expectEqual(@as(u32, 0), stepBrightness(1, false));
    try std.testing.expectEqual(@as(u32, 12), stepBrightness(10, true));
}
