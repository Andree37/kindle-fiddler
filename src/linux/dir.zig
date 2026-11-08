//! Finding files under a folder, with raw getdents64.
const std = @import("std");
const linux = std.os.linux;
const os = @import("os.zig");

const max_depth = 6;

/// Paths of the files under `root` whose names end with `suffix`. Hidden folders
/// and the Kindle's ".sdr" sidecar folders are skipped.
pub fn findFiles(alloc: std.mem.Allocator, root: []const u8, suffix: []const u8) ![][:0]u8 {
    var out: std.ArrayList([:0]u8) = .empty;
    try walk(alloc, root, suffix, 0, &out);
    return out.toOwnedSlice(alloc);
}

fn walk(alloc: std.mem.Allocator, dir: []const u8, suffix: []const u8, depth: u32, out: *std.ArrayList([:0]u8)) !void {
    if (depth > max_depth) return;
    const path = try alloc.dupeSentinel(u8, dir, 0);
    defer alloc.free(path);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (os.failed(rc)) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (os.failed(n) or n == 0) return;
        var at: usize = 0;
        while (at + 19 < n) {
            // struct linux_dirent64: inode u64, offset i64, record length u16, type u8, name.
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            if (reclen == 0 or at + reclen > n) return;
            const kind = buf[at + 18];
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.') continue;
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
            defer alloc.free(full);
            const is_dir = kind == 4;
            if (is_dir) {
                if (!std.mem.endsWith(u8, name, ".sdr")) try walk(alloc, full, suffix, depth + 1, out);
            } else if (std.ascii.endsWithIgnoreCase(name, suffix)) {
                try out.append(alloc, try alloc.dupeSentinel(u8, full, 0));
            }
        }
    }
}
