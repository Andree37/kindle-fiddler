//! Records the framebuffer as a run of small frames, for demo videos and for timing
//! how soon a screen is drawn after a touch. Each frame keeps every `scale`-th pixel
//! of every `scale`-th row, prefixed by when it was taken (monotonic microseconds,
//! the clock touchsim prints). It reads only those rows, so the screen's slow memory
//! isn't read whole.
//! Usage: fbrec <seconds> <frames-per-second> <scale> <out-file>
//! Output: "FBREC <width> <height>\n", then per frame an 8-byte little-endian
//! timestamp and width*height gray bytes.
const std = @import("std");
const core = @import("core");
const linux = std.os.linux;
const nowUs = core.os.nowUs;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 5) return error.Usage;
    const seconds = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[1], 0), 10);
    const fps = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10);
    const scale = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[3], 0), 10);
    if (fps == 0 or scale == 0) return error.Usage;

    const fb: i32 = @intCast(linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY }, 0));
    var v: [160]u8 align(4) = undefined;
    _ = linux.ioctl(fb, 0x4600, @intFromPtr(&v)); // FBIOGET_VSCREENINFO
    const width: u32 = std.mem.readInt(u32, v[0..4], .little);
    const height: u32 = std.mem.readInt(u32, v[4..8], .little);
    const yoffset: u32 = std.mem.readInt(u32, v[20..24], .little);
    const out_w = width / scale;
    const out_h = height / scale;

    const rc = linux.open(argv[4], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (core.os.failed(rc)) return error.CantWrite;
    const out: i32 = @intCast(rc);
    defer _ = linux.close(out);
    var head: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&head, "FBREC {d} {d}\n", .{ out_w, out_h });
    _ = linux.write(out, h.ptr, h.len);

    const frame = try std.heap.page_allocator.alloc(u8, 8 + out_w * out_h);
    var row: [4096]u8 = undefined;
    const step_us: u64 = 1_000_000 / fps;
    const end = nowUs() + @as(u64, seconds) * 1_000_000;
    var next = nowUs();
    var frames: u32 = 0;
    while (nowUs() < end) {
        const t = nowUs();
        std.mem.writeInt(u64, frame[0..8], t, .little);
        for (0..out_h) |y| {
            const off: i64 = @as(i64, yoffset + @as(u32, @intCast(y)) * scale) * width;
            _ = linux.pread(fb, &row, width, off);
            const dst = frame[8 + y * out_w ..][0..out_w];
            for (dst, 0..) |*d, x| d.* = row[x * scale];
        }
        _ = linux.write(out, frame.ptr, frame.len);
        frames += 1;
        next += step_us;
        const now = nowUs();
        if (next > now) core.os.sleepMs((next - now) / 1000);
    }
    std.debug.print("fbrec: {d} frames of {d}x{d}\n", .{ frames, out_w, out_h });
}
