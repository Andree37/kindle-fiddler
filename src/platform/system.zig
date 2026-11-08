//! Device settings, changed through Amazon's lipc command line tools.
const std = @import("std");
const linux = std.os.linux;
const os = @import("os.zig");
const annotations = @import("../book/annotations.zig");

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
    syncing: bool = false,
    battery: u32 = 0,
    wifi_on: bool = false,
    wifi_bars: u32 = 0, // 0 to 3
    clock: [40]u8 = undefined,
    clock_len: usize = 0,

    pub fn clockText(q: *const Quick) []const u8 {
        return q.clock[0..q.clock_len];
    }
};

const failed = os.failed;

pub const Child = struct { pid: i32, out: i32 };

/// Starts a program with its output on a pipe, in a process group of its own so
/// everything it starts can be killed together.
fn spawn(argv: [*:null]const ?[*:0]const u8) ?Child {
    var fds: [2]i32 = undefined;
    // Close-on-exec, so later children don't inherit this pipe. dup2 below clears it on
    // the child's own stdout.
    if (failed(linux.pipe2(&fds, .{ .CLOEXEC = true }))) return null;
    const pid = linux.fork();
    if (failed(pid)) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0].?, argv, &envp);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    return .{ .pid = @intCast(pid), .out = fds[0] };
}

/// Longest any command may take. A stuck lipc or sqlite call must not freeze the reader.
const command_timeout_ms = 15_000;

/// Runs a command, collecting what it prints. Null when it can't start or runs too long,
/// in which case it is killed.
fn run(argv: [*:null]const ?[*:0]const u8, out: []u8) ?usize {
    return runUntil(argv, out, os.nowUs() + command_timeout_ms * 1000);
}

/// Like `run`, but must be done by `deadline` (microseconds on the monotonic clock).
fn runUntil(argv: [*:null]const ?[*:0]const u8, out: []u8, deadline: u64) ?usize {
    if (os.nowUs() >= deadline) return null;
    const child = spawn(argv) orelse return null;
    var total: usize = 0;
    while (total < out.len) {
        const now = os.nowUs();
        if (now >= deadline) break;
        var ready = [_]linux.pollfd{.{ .fd = child.out, .events = linux.POLL.IN, .revents = 0 }};
        const waited = linux.poll(&ready, 1, @intCast((deadline - now) / 1000 + 1));
        if (failed(waited)) continue; // Interrupted by a signal
        if (waited == 0) break;
        const n = linux.read(child.out, out[total..].ptr, out.len - total);
        if (failed(n) or n == 0) break;
        total += n;
    }
    // Closing first means a child with more to say gets SIGPIPE instead of blocking.
    _ = linux.close(child.out);
    if (!reap(child.pid, deadline)) {
        std.debug.print("command timed out: {s}\n", .{std.mem.sliceTo(argv[0].?, 0)});
        return null;
    }
    return total;
}

/// Waits for a child to exit until `deadline`, then kills its whole group. For
/// `sh -c`, the stuck program is the shell's child. True when it exited in time.
fn reap(pid: i32, deadline: u64) bool {
    var status: i32 = 0;
    while (true) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) != 0) return true;
        if (os.nowUs() >= deadline) break;
        os.sleepMs(5);
    }
    _ = linux.kill(-pid, linux.SIG.KILL);
    _ = linux.waitpid(pid, &status, 0);
    return false;
}

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
    const n = runUntil(&argv, &buf, deadline) orelse return null;
    return parseInt(buf[0..n]);
}

fn set(service: [*:0]const u8, prop: [*:0]const u8, value: u32) void {
    var text: [16]u8 = undefined;
    const arg = std.fmt.bufPrintSentinel(&text, "{d}", .{value}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ lipc_set, service, prop, arg };
    var buf: [32]u8 = undefined;
    _ = runUntil(&argv, &buf, lipcDeadline());
}

fn getText(service: [*:0]const u8, prop: [*:0]const u8, buf: []u8, deadline: u64) []const u8 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, "-s", service, prop };
    const n = runUntil(&argv, buf, deadline) orelse return "";
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
pub fn read(previous: Quick) Quick {
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
    if (runUntil(&argv, &clock, deadline)) |n| {
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

/// Catalog IDs go into a shell command, so only plain ones are accepted.
pub fn safeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// Book GUIDs look like "CR!0123ABC". Empty is fine: sideloaded books have none.
pub fn safeGuid(guid: []const u8) bool {
    if (guid.len > 64) return false;
    for (guid) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '!' and c != '-' and c != '_' and c != '.') return false;
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
    const rc = linux.open("/tmp/noface-dry-run", .{ .ACCMODE = .RDONLY }, 0);
    if (failed(rc)) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

/// Fetches a book's highlights or bookmarks as "id|start|end" lines.
pub fn readAnnotations(key: []const u8, kind: annotations.Kind, out: []u8) []const u8 {
    if (!safeId(key)) return "";
    var match_buf: [128]u8 = undefined;
    const book = annotations.bookMatch(&match_buf, key) catch return "";
    var buf: [1000]u8 = undefined;
    const fields = "annotation_id, json_extract(serialized_payload, '$.start_position.shortPosition'), json_extract(serialized_payload, '$.end_position.shortPosition')";
    const command = std.fmt.bufPrintSentinel(&buf,
        \\sqlite3 -separator '|' "file:$(ls /mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db)?mode=ro" "select {s} from server_view where dataset={d} and {s} and annotation_id not in (select annotation_id from local_edit where {s}) union select {s} from local_edit where dataset={d} and action != 3 and {s}"
    , .{ fields, kind.dataset(), book, book, fields, kind.dataset(), book }, 0) catch return "";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const n = run(&argv, out) orelse return "";
    return completeLines(out[0..n], n == out.len);
}

/// Output that filled its buffer may end mid-line; that last line is dropped
/// rather than read as a highlight with a wrong end.
pub fn completeLines(output: []const u8, filled: bool) []const u8 {
    if (!filled) return output;
    std.debug.print("highlight list cut off at {d} bytes\n", .{output.len});
    const end = std.mem.lastIndexOfScalar(u8, output, '\n') orelse return "";
    return output[0 .. end + 1];
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
    const command = "sqlite3 -bail -cmd '.timeout 3000' /mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db < " ++ path ++ " && echo ok";
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

/// Starts a child that prints power events. Its `out` pipe is non-blocking.
pub fn watchPowerEvents() ?Child {
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/lipc-wait-event", "-m", "com.lab126.powerd", "goingToScreenSaver,outOfScreenSaver" };
    const child = spawn(&argv) orelse return null;
    const flags = linux.fcntl(child.out, linux.F.GETFL, 0);
    _ = linux.fcntl(child.out, linux.F.SETFL, flags | 0o4000); // O_NONBLOCK
    return child;
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

/// Same as the Sync button in the stock panel.
pub fn syncNow() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", "com.lab126.quickactions", "syncAndCheck", "1" };
    var out: [32]u8 = undefined;
    _ = run(&argv, &out);
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

test "guids are checked before they reach SQL" {
    try std.testing.expect(safeGuid("CR!0000000000000000000000000000"));
    try std.testing.expect(safeGuid(""));
    try std.testing.expect(!safeGuid("CR!1' or 1=1 --"));
    try std.testing.expect(!safeGuid("a\"b"));
}

test "a cut-off highlight list loses only its partial line" {
    try std.testing.expectEqualStrings("a|1|2\nb|3|4\n", completeLines("a|1|2\nb|3|4\nc|5|", true));
    try std.testing.expectEqualStrings("a|1|2\nc|5|6", completeLines("a|1|2\nc|5|6", false));
    try std.testing.expectEqualStrings("", completeLines("c|5|", true));
}
