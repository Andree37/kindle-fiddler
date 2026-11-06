//! Read-only memory mapping of a file, using raw Linux syscalls.
const std = @import("std");
const linux = std.os.linux;

pub fn map(path: [*:0]const u8) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd > std.math.maxInt(usize) - 4096) return error.OpenFailed;
    var end: i64 = 0;
    _ = linux.llseek(@intCast(fd), 0, &end, 2); // SEEK_END
    const size: usize = @intCast(end);
    const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, @intCast(fd), 0);
    if (addr > std.math.maxInt(usize) - 4096) return error.MmapFailed;
    return @as([*]const u8, @ptrFromInt(addr))[0..size];
}

pub fn unmap(data: []const u8) void {
    _ = linux.munmap(data.ptr, data.len);
}
