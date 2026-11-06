//! Direct access to the Kindle Paperwhite 12th gen e-ink driver (MediaTek hwtcon_v2).
//! Struct layout and ioctl numbers follow FBInk's eink/mtk-kindle.h.
const std = @import("std");
const linux = std.os.linux;

pub const Waveform = enum(u32) {
    du = 1,
    gc16 = 2,
    gl16 = 3,
    reagl = 4,
    a2 = 6,
    du4 = 7,
};

pub const UpdateMode = enum(u32) { partial = 0, full = 1 };

const Rect = extern struct { top: u32, left: u32, width: u32, height: u32 };

const AltBuffer = extern struct {
    phys_addr: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    region: Rect = .{ .top = 0, .left = 0, .width = 0, .height = 0 },
};

const UpdateData = extern struct {
    region: Rect,
    waveform: u32,
    update_mode: u32,
    marker: u32,
    temp: i32 = temp_use_ambient,
    flags: u32 = 0,
    dither_mode: i32 = 0,
    quant_bit: i32 = 0,
    alt: AltBuffer = .{},
    swipe_direction: u32 = 0,
    swipe_steps: u32 = 0,
    hist_bw_waveform: u32 = 0,
    hist_gray_waveform: u32 = 0,
    ts_pxp: u32 = 0,
    ts_epdc: u32 = 0,
};

const MarkerData = extern struct { marker: u32, collision_test: u32 = 0 };

comptime {
    std.debug.assert(@sizeOf(UpdateData) == 96);
}

const temp_use_ambient = 0x1000;
const send_update: u32 = 0x4060462E; // _IOW('F', 0x2E, 96 bytes)
const wait_complete: u32 = 0xC008462F; // _IOWR('F', 0x2F, 8 bytes)
const fbioget_vscreeninfo: u32 = 0x4600;
const fbioget_fscreeninfo: u32 = 0x4602;

pub const Screen = struct {
    fd: i32,
    map: []align(4096) u8,
    pixels: []u8, // visible page only
    width: u32,
    height: u32,
    stride: u32,
    next_marker: u32 = 0x7000,

    pub fn open() !Screen {
        const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDWR }, 0);
        if (failed(rc)) return error.OpenFailed;
        const fd: i32 = @intCast(rc);

        var v: [160]u8 align(4) = undefined;
        var f: [68]u8 align(4) = undefined;
        if (failed(linux.ioctl(fd, fbioget_vscreeninfo, @intFromPtr(&v)))) return error.VScreenInfo;
        if (failed(linux.ioctl(fd, fbioget_fscreeninfo, @intFromPtr(&f)))) return error.FScreenInfo;

        const width = std.mem.readInt(u32, v[0..4], .little);
        const height = std.mem.readInt(u32, v[4..8], .little);
        const yoffset = std.mem.readInt(u32, v[20..24], .little);
        const bpp = std.mem.readInt(u32, v[24..28], .little);
        const smem_len = std.mem.readInt(u32, f[20..24], .little);
        const stride = std.mem.readInt(u32, f[44..48], .little);
        if (bpp != 8) return error.UnexpectedDepth;

        const addr = linux.mmap(null, smem_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (failed(addr)) return error.MmapFailed;
        const map = @as([*]align(4096) u8, @ptrFromInt(addr))[0..smem_len];

        const start = @as(usize, yoffset) * stride;
        return .{
            .fd = fd,
            .map = map,
            .pixels = map[start..][0 .. @as(usize, height) * stride],
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    /// Queue a whole-screen update and return its marker.
    pub fn update(s: *Screen, waveform: Waveform, mode: UpdateMode) !u32 {
        return s.updateRegion(0, 0, s.width, s.height, waveform, mode);
    }

    /// Queue an update for part of the screen and return its marker.
    pub fn updateRegion(s: *Screen, left: u32, top: u32, width: u32, height: u32, waveform: Waveform, mode: UpdateMode) !u32 {
        const marker = s.next_marker;
        s.next_marker += 1;
        var data = UpdateData{
            .region = .{ .top = top, .left = left, .width = width, .height = height },
            .waveform = @intFromEnum(waveform),
            .update_mode = @intFromEnum(mode),
            .marker = marker,
        };
        if (failed(linux.ioctl(s.fd, send_update, @intFromPtr(&data)))) return error.SendUpdate;
        return marker;
    }

    pub fn waitComplete(s: *Screen, marker: u32) !void {
        var data = MarkerData{ .marker = marker };
        if (failed(linux.ioctl(s.fd, wait_complete, @intFromPtr(&data)))) return error.WaitComplete;
    }
};

fn failed(rc: usize) bool {
    return rc > std.math.maxInt(usize) - 4096;
}
