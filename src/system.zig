//! Device settings, changed through Amazon's lipc command line tools.
const std = @import("std");
const linux = std.os.linux;

const lipc_get: [*:0]const u8 = "/usr/bin/lipc-get-prop";
const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

pub const max_brightness = 24;
pub const max_warmth = 24;
pub const brightness_step = 2;

pub const Quick = struct {
    brightness: u32 = 0,
    warmth: u32 = 0,
    schedule: bool = false,
    airplane: bool = false,
    battery: u32 = 0,
    wifi_on: bool = false,
    wifi_bars: u32 = 0, // 0 to 3
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

fn getText(service: [*:0]const u8, prop: [*:0]const u8, buf: []u8) []const u8 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, "-s", service, prop };
    const n = run(&argv, buf) orelse return "";
    return std.mem.trim(u8, buf[0..n], " \n");
}

/// Maps wifid's "5/5" to the three arcs of the icon.
pub fn signalBars(signal: []const u8) u32 {
    const value = std.fmt.parseInt(u32, signal[0 .. std.mem.indexOfScalar(u8, signal, '/') orelse return 0], 10) catch return 0;
    return @min((value + 1) / 2, 3);
}

pub fn read() Quick {
    var state_buf: [32]u8 = undefined;
    var signal_buf: [16]u8 = undefined;
    const connected = std.mem.eql(u8, getText("com.lab126.wifid", "cmState", &state_buf), "CONNECTED");
    var q = Quick{
        .wifi_on = connected,
        .wifi_bars = if (connected) signalBars(getText("com.lab126.wifid", "signalStrength", &signal_buf)) else 0,
        .brightness = get("com.lab126.powerd", "flIntensity") orelse 0,
        .warmth = get("com.lab126.powerd", "currentAmberLevel") orelse 0,
        .schedule = (get("com.lab126.powerd", "amberSchedEnable") orelse 0) == 1,
        .airplane = (get("com.lab126.cmd", "wirelessEnable") orelse 1) == 0,
        .battery = get("com.lab126.powerd", "battLevel") orelse 0,
    };
    const argv = [_:null]?[*:0]const u8{ "/bin/date", "+%H:%M - %d %b %Y" };
    if (run(&argv, &q.clock)) |n| q.clock_len = std.mem.trimEnd(u8, q.clock[0..n], "\n").len;
    return q;
}

/// Catalog IDs go into a shell command, so only plain ones are accepted.
pub fn safeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

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
    _ = run(&argv, &out);
}

/// Queues a cloud book for download.
pub fn downloadBook(key: []const u8, kind: []const u8) void {
    if (!safeId(key) or !safeId(kind)) return;
    readNowAction("kppDownloadAction", "kppItems = \"{s},{s}\"", .{ key, kind });
}

/// Removes the local copy. Never sets kppFrom: "cloud" there revokes samples.
pub fn removeDownload(key: []const u8, kind: []const u8) void {
    if (!safeId(key) or !safeId(kind)) return;
    readNowAction("kppDeleteItemAction", "kppCdeKey = \"{s}\", kppCdeType = \"{s}\"", .{ key, kind });
}

pub fn markRead(key: []const u8, kind: []const u8, read_it: bool) void {
    if (!safeId(key) or !safeId(kind)) return;
    const value = if (read_it) "actionRead" else "actionUnread";
    readNowAction("kppMarkAsReadAction", "kppCdeKey = \"{s}\", kppCdeType = \"{s}\", kppMAR = \"{s}\"", .{ key, kind, value });
}

/// While this file exists, annotation writes are skipped. Used by device tests.
pub fn dryRun() bool {
    return !failed(linux.open("/tmp/noface-dry-run", .{ .ACCMODE = .RDONLY }, 0));
}

/// Fetches a book's highlights as "id|start|end" lines.
pub fn readHighlights(key: []const u8, out: []u8) []const u8 {
    if (!safeId(key)) return "";
    var buf: [900]u8 = undefined;
    const fields = "annotation_id, json_extract(serialized_payload, '$.start_position.shortPosition'), json_extract(serialized_payload, '$.end_position.shortPosition')";
    const command = std.fmt.bufPrintSentinel(&buf,
        \\sqlite3 -separator '|' "file:$(ls /mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db)?mode=ro" "select {s} from server_view where dataset=1 and dataset_id like '{s}-%' and annotation_id not in (select annotation_id from local_edit) union select {s} from local_edit where dataset=1 and action != 3 and dataset_id like '{s}-%'"
    , .{ fields, key, fields, key }, 0) catch return "";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const n = run(&argv, out) orelse return "";
    return out[0..n];
}

/// Runs a SQL statement against the annotation database.
pub fn runAnnotationSql(sql: []const u8) bool {
    const path = "/tmp/noface-annotation.sql";
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (failed(rc)) return false;
    const fd: i32 = @intCast(rc);
    const written = linux.write(fd, sql.ptr, sql.len);
    _ = linux.close(fd);
    if (failed(written) or written != sql.len) return false;
    const command = "sqlite3 /mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db < " ++ path ++ " && echo ok";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    var out: [8]u8 = undefined;
    const n = run(&argv, &out) orelse return false;
    return std.mem.startsWith(u8, out[0..n], "ok");
}

/// Rebuilds library.tsv from the catalog.
pub fn exportLibrary() void {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "/mnt/us/noface/export.sh" };
    var out: [16]u8 = undefined;
    _ = run(&argv, &out);
}

/// Starts a child that prints power events, and returns the pipe it writes to.
pub fn watchPowerEvents() ?i32 {
    var fds: [2]i32 = undefined;
    if (failed(linux.pipe(&fds))) return null;
    const pid = linux.fork();
    if (failed(pid)) return null;
    if (pid == 0) {
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/lipc-wait-event", "-m", "com.lab126.powerd", "goingToScreenSaver,outOfScreenSaver" };
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0].?, &argv, &envp);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    const flags = linux.fcntl(fds[0], linux.F.GETFL, 0);
    _ = linux.fcntl(fds[0], linux.F.SETFL, flags | 0o4000); // O_NONBLOCK
    return fds[0];
}

/// Turns date's "+0100" into seconds.
pub fn parseOffset(zone: []const u8) i64 {
    if (zone.len < 5) return 0;
    const hours = std.fmt.parseInt(i64, zone[1..3], 10) catch return 0;
    const minutes = std.fmt.parseInt(i64, zone[3..5], 10) catch return 0;
    const seconds = hours * 3600 + minutes * 60;
    return if (zone[0] == '-') -seconds else seconds;
}

/// The device's offset from UTC, so the clock needs no process per minute.
pub fn utcOffset() i64 {
    const argv = [_:null]?[*:0]const u8{ "/bin/date", "+%z" };
    var buf: [16]u8 = undefined;
    const n = run(&argv, &buf) orelse return 0;
    return parseOffset(std.mem.trim(u8, buf[0..n], " \n"));
}

/// "HH:MM" for a Unix time.
pub fn formatClock(buf: []u8, unix: i64, offset: i64) []const u8 {
    const minutes: u32 = @intCast(@divFloor(@mod(unix + offset, 86400), 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes / 60, minutes % 60 }) catch "";
}

pub fn openSettings() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "com.lab126.appmgrd", "start", "app://com.lab126.booklet.settings" };
    var buf: [32]u8 = undefined;
    _ = run(&argv, &buf);
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

/// Steps brightness, stopping at both ends.
pub fn stepBrightness(level: u32, up: bool) u32 {
    if (up) return @min(level + brightness_step, max_brightness);
    return level -| brightness_step;
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

test "ids that could break out of the shell command are refused" {
    try std.testing.expect(safeId("FEDCBA9876543210FEDCBA9876543210"));
    try std.testing.expect(safeId("PDOC"));
    try std.testing.expect(!safeId(""));
    try std.testing.expect(!safeId("a'; rm -rf /"));
    try std.testing.expect(!safeId("a b"));
}

test "clock formats local time" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", formatClock(&buf, 0, 0));
    try std.testing.expectEqualStrings("01:05", formatClock(&buf, 300, 3600));
    try std.testing.expectEqualStrings("23:30", formatClock(&buf, 0, -1800));
}

test "zone offsets parse" {
    try std.testing.expectEqual(@as(i64, 3600), parseOffset("+0100"));
    try std.testing.expectEqual(@as(i64, -19800), parseOffset("-0530"));
    try std.testing.expectEqual(@as(i64, 0), parseOffset(""));
}

test "brightness stops at both ends" {
    try std.testing.expectEqual(@as(u32, 24), stepBrightness(23, true));
    try std.testing.expectEqual(@as(u32, 0), stepBrightness(1, false));
    try std.testing.expectEqual(@as(u32, 12), stepBrightness(10, true));
}
