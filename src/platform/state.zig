//! Per-book reading state, kept in small text files beside the reader.
const std = @import("std");
const linux = std.os.linux;

pub const State = struct {
    para: usize = 0,
    byte: usize = 0,
    percent: ?u32 = null,
    opened: u64 = 0,
    seconds: u64 = 0, // Time spent reading this book
};

const failed = @import("os.zig").failed;

/// `<dir>/state-<first 16 hex of md5 of "basename\n">`, matching earlier versions
/// that named these files with `basename | md5sum`.
pub fn pathFor(buf: []u8, dir: []const u8, book_path: []const u8) ![:0]u8 {
    const name = std.fs.path.basename(book_path);
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(name);
    md5.update("\n");
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    return std.fmt.bufPrintSentinel(buf, "{s}/state-{s}", .{ dir, &hex }, 0);
}

/// True when the Kindle's own position should win over ours: we have nothing
/// saved, or the stock reader had the book open more recently.
pub fn preferKindle(saved: State, kindle_last: u64) bool {
    // Older files have no time, so only an empty one gives way.
    if (saved.opened == 0) return saved.para == 0 and saved.byte == 0;
    return kindle_last > saved.opened;
}

pub fn parse(content: []const u8) State {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    var s = State{};
    s.para = std.fmt.parseInt(usize, it.next() orelse return .{}, 10) catch return .{};
    s.byte = std.fmt.parseInt(usize, it.next() orelse return .{}, 10) catch return .{};
    s.percent = if (it.next()) |p| std.fmt.parseInt(u32, p, 10) catch null else null;
    s.opened = if (it.next()) |o| std.fmt.parseInt(u64, o, 10) catch 0 else 0;
    s.seconds = if (it.next()) |o| std.fmt.parseInt(u64, o, 10) catch 0 else 0;
    return s;
}

pub fn load(path: [*:0]const u8) State {
    var buf: [128]u8 = undefined;
    return parse(readSmall(path, &buf));
}

/// A small file's contents, or nothing if it can't be read.
pub fn readSmall(path: [*:0]const u8, buf: []u8) []const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    return if (failed(n)) "" else buf[0..n];
}

/// Writes beside the real file and renames, so a crash can't lose the old contents.
pub fn writeSmall(path: [*:0]const u8, data: []const u8) void {
    var tmp: [320]u8 = undefined;
    const name = std.mem.sliceTo(path, 0);
    const tmp_path = std.fmt.bufPrintSentinel(&tmp, "{s}.tmp", .{name}, 0) catch return;
    const rc = linux.open(tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (failed(rc)) return;
    const fd: i32 = @intCast(rc);
    const written = linux.write(fd, data.ptr, data.len);
    _ = linux.close(fd);
    if (failed(written) or written != data.len or data.len == 0) return;
    _ = linux.rename(tmp_path, path);
}

pub fn save(path: [*:0]const u8, s: State) void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d} {d} {d} {d} {d}\n", .{ s.para, s.byte, s.percent orelse 0, s.opened, s.seconds }) catch return;
    writeSmall(path, line);
}

test "state file name matches basename piped to md5sum" {
    var buf: [128]u8 = undefined;
    // printf 'abc\n' | md5sum starts 0bee89b07a248e27
    const p = try pathFor(&buf, "/d", "/books/abc");
    try std.testing.expectEqualStrings("/d/state-0bee89b07a248e27", p);
}

test "old two-field files still load" {
    const s = parse("8 7957\n");
    try std.testing.expectEqual(@as(usize, 8), s.para);
    try std.testing.expectEqual(@as(usize, 7957), s.byte);
    try std.testing.expect(s.percent == null);
}

test "new files keep percent and time" {
    const s = parse("1 2 37 1793990000\n");
    try std.testing.expectEqual(@as(u32, 37), s.percent.?);
    try std.testing.expectEqual(@as(u64, 1793990000), s.opened);
}

test "kindle position wins until we have our own" {
    try std.testing.expect(preferKindle(.{}, 100));
    try std.testing.expect(preferKindle(.{ .para = 5, .opened = 100 }, 200));
    try std.testing.expect(!preferKindle(.{ .para = 5, .opened = 300 }, 200));
    try std.testing.expect(!preferKindle(.{ .para = 5 }, 200));
}

test "reading time is kept, and older files read as none" {
    try std.testing.expectEqual(@as(u64, 4200), parse("1 2 37 1793990000 4200\n").seconds);
    try std.testing.expectEqual(@as(u64, 0), parse("1 2 37 1793990000\n").seconds);
}
