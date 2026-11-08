//! Amazon's lipc services: light, warmth, wireless, sync, settings and power events.
//! Every call goes through the lipc command line tools.
const std = @import("std");
const linux = std.os.linux;
const os = @import("../linux/os.zig");
const process = @import("../linux/process.zig");
const quick_model = @import("../model/quick.zig");

const lipc_get: [*:0]const u8 = "/usr/bin/lipc-get-prop";

const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

pub fn parseInt(output: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, output, " \n"), 10) catch null;
}

/// Settings calls answer at once when lipc is healthy; when it isn't, give up fast.
const lipc_timeout_ms = 3000;

fn lipcDeadline() u64 {
    return os.nowUs() + lipc_timeout_ms * 1000;
}

fn get(service: [*:0]const u8, prop: [*:0]const u8, deadline: u64) ?u32 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, service, prop };
    var buf: [32]u8 = undefined;
    const n = process.runUntil(&argv, &buf, deadline) orelse return null;
    return parseInt(buf[0..n]);
}

fn set(service: [*:0]const u8, prop: [*:0]const u8, value: u32) void {
    var text: [16]u8 = undefined;
    const arg = std.fmt.bufPrintSentinel(&text, "{d}", .{value}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ lipc_set, service, prop, arg };
    var buf: [32]u8 = undefined;
    _ = process.runUntil(&argv, &buf, lipcDeadline());
}

fn getText(service: [*:0]const u8, prop: [*:0]const u8, buf: []u8, deadline: u64) []const u8 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, "-s", service, prop };
    const n = process.runUntil(&argv, buf, deadline) orelse return "";
    return std.mem.trim(u8, buf[0..n], " \n");
}

/// Maps wifid's "5/5" to the three arcs of the icon.
pub fn signalBars(signal: []const u8) u32 {
    const value = std.fmt.parseInt(u32, signal[0 .. std.mem.indexOfScalar(u8, signal, '/') orelse return 0], 10) catch return 0;
    return @min((value + 1) / 2, 3);
}

/// Everything the panel and status bar show. All reads share one short deadline,
/// so a hung lipc costs one wait, not one per value. A value that can't be read keeps
/// what `previous` had, so the panel never acts on a made-up zero.
pub fn read(previous: quick_model.Quick) quick_model.Quick {
    const deadline = lipcDeadline();
    var q = previous;
    var state_buf: [32]u8 = undefined;
    const wifi_state = getText("com.lab126.wifid", "cmState", &state_buf, deadline);
    if (wifi_state.len > 0) {
        q.wifi_on = std.mem.eql(u8, wifi_state, "CONNECTED");
        q.wifi_bars = 0;
        if (q.wifi_on) {
            var signal_buf: [16]u8 = undefined;
            q.wifi_bars = signalBars(getText("com.lab126.wifid", "signalStrength", &signal_buf, deadline));
        }
    }
    if (get("com.lab126.powerd", "flIntensity", deadline)) |v| q.brightness = v;
    if (get("com.lab126.powerd", "currentAmberLevel", deadline)) |v| q.warmth = v;
    if (get("com.lab126.powerd", "amberSchedEnable", deadline)) |v| q.schedule = v == 1;
    if (get("com.lab126.cmd", "wirelessEnable", deadline)) |v| q.airplane = v == 0;
    if (get("com.lab126.powerd", "battLevel", deadline)) |v| q.battery = v;
    const argv = [_:null]?[*:0]const u8{ "/bin/date", "+%H:%M - %d %b %Y" };
    var clock: [40]u8 = undefined;
    if (process.runUntil(&argv, &clock, deadline)) |n| {
        q.clock = clock;
        q.clock_len = std.mem.trimEnd(u8, clock[0..n], "\n").len;
    }
    return q;
}

/// Whether the Kindle is showing its lock screen. Null when powerd can't be asked.
pub fn inScreenSaver() ?bool {
    var buf: [32]u8 = undefined;
    const state = getText("com.lab126.powerd", "state", &buf, lipcDeadline());
    if (state.len == 0) return null;
    return std.mem.eql(u8, state, "screenSaver");
}

/// Starts a child that prints power events. Its `out` pipe is non-blocking.
pub fn watchPowerEvents() ?process.Child {
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/lipc-wait-event", "-m", "com.lab126.powerd", "goingToScreenSaver,outOfScreenSaver" };
    const child = process.spawn(&argv) orelse return null;
    const flags = linux.fcntl(child.out, linux.F.GETFL, 0);
    _ = linux.fcntl(child.out, linux.F.SETFL, flags | 0o4000); // O_NONBLOCK
    return child;
}

/// Same as the Sync button in the stock panel.
pub fn syncNow() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", "com.lab126.quickactions", "syncAndCheck", "1" };
    var out: [32]u8 = undefined;
    _ = process.run(&argv, &out);
}

pub fn openSettings() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "com.lab126.appmgrd", "start", "app://com.lab126.booklet.settings" };
    var buf: [32]u8 = undefined;
    _ = process.run(&argv, &buf);
}

pub fn setBrightness(level: u32) void {
    set("com.lab126.powerd", "flIntensity", level);
}

/// With the schedule on, its own level has to move too or it would snap back.
pub fn setWarmth(level: u32, scheduled: bool) void {
    set("com.lab126.powerd", "currentAmberLevel", level);
    if (scheduled) set("com.lab126.powerd", "schedAmberLevel", level);
}

pub fn setSchedule(on: bool) void {
    set("com.lab126.powerd", "amberSchedEnable", if (on) 1 else 0);
}

pub fn setAirplane(on: bool) void {
    set("com.lab126.cmd", "wirelessEnable", if (on) 0 else 1);
}

test "tool output parses" {
    try std.testing.expectEqual(@as(u32, 21), parseInt("21\n").?);
    try std.testing.expect(parseInt("failed\n") == null);
}

test "signal maps to icon arcs" {
    try std.testing.expectEqual(@as(u32, 3), signalBars("5/5"));
    try std.testing.expectEqual(@as(u32, 2), signalBars("3/5"));
    try std.testing.expectEqual(@as(u32, 1), signalBars("1/5"));
    try std.testing.expectEqual(@as(u32, 0), signalBars("none"));
}
