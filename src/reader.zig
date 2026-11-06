//! Fast page-turning reader. Usage: reader <book.kfx> <font.ttf> <state-file>
//!
//! Touch-down turns the page: left third goes back, the rest goes forward.
//! Hold the top-left corner for one second to quit. The power button quits too.
const std = @import("std");
const linux = std.os.linux;
const cache = @import("cache.zig");
const file = @import("file.zig");
const hwtcon = @import("hwtcon.zig");
const kfx = @import("kfx.zig");
const text = @import("text.zig");

const page_waveform: hwtcon.Waveform = .reagl;
const clean_refresh_every = 20;
const idle_quit_ms = 30 * 60 * 1000;
const corner_hold_ms = 1000;
const save_every = 10;
const grip_strip_px = 120; // Bottom edge, where a holding thumb rests

const touch_device = "/dev/input/event1";
const power_device = "/dev/input/event0";
const eviocgrab: u32 = 0x40044590;
const eviocsclockid: u32 = 0x400445a0;
const eviocgabs_x: u32 = 0x80184540 + 0x35;
const eviocgabs_y: u32 = 0x80184540 + 0x36;

const ev_key = 1;
const ev_abs = 3;
const abs_mt_slot = 0x2f;
const abs_mt_touch_major = 0x30;
const abs_mt_x = 0x35;
const abs_mt_y = 0x36;
const abs_mt_tracking = 0x39;

const InputEvent = extern struct { sec: u32, usec: u32, kind: u16, code: u16, value: i32 };

var stop_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

fn installSignals() void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = onSignal };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &act, null);
}

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn failed(rc: usize) bool {
    return rc > std.math.maxInt(usize) - 4096;
}

fn openInput(path: [*:0]const u8) !i32 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    if (failed(rc)) return error.InputOpen;
    const fd: i32 = @intCast(rc);
    var clock: i32 = 1; // CLOCK_MONOTONIC, so event times compare with nowUs
    _ = linux.ioctl(fd, eviocsclockid, @intFromPtr(&clock));
    return fd;
}

fn axisMax(fd: i32, req: u32) i32 {
    var info = std.mem.zeroes([6]i32);
    _ = linux.ioctl(fd, req, @intFromPtr(&info));
    return info[2];
}

const Slot = struct { page: i64 = -1, buf: []u8 };

const Reader = struct {
    screen: *hwtcon.Screen,
    font: *text.Font,
    footer: *text.Font,
    book: kfx.Book,
    layout: text.Layout,
    pages: []const text.Pos,
    slots: [3]Slot,
    current: usize = 0,
    turns: u32 = 0,

    fn geometry(r: *Reader, buf: []u8) text.Page {
        return .{ .buf = buf, .width = r.screen.width, .height = r.screen.height, .stride = r.screen.stride };
    }

    /// Get a rendered page, reusing a cached one when possible.
    fn ensure(r: *Reader, index: usize, center: usize) ![]const u8 {
        for (r.slots) |s| {
            if (s.page == @as(i64, @intCast(index))) return s.buf;
        }
        var cached: [3]i64 = undefined;
        for (r.slots, &cached) |s, *c| c.* = s.page;
        const victim = cache.victim(cached, @intCast(center));
        const buf = r.slots[victim].buf;
        const page = r.geometry(buf);
        _ = try text.renderPage(r.font, page, r.book.paragraphs, r.pages[index], r.layout);

        var label: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, r.pages.len }) catch "";
        const x = @as(f32, @floatFromInt(r.screen.width)) / 2 - 50;
        try r.footer.draw(page, x, @intCast(r.screen.height - 60), s);

        r.slots[victim].page = @intCast(index);
        return buf;
    }

    fn show(r: *Reader, index: usize, touched_us: ?u64, force_clean: bool) !void {
        const buf = try r.ensure(index, index);
        @memcpy(r.screen.pixels, buf);
        r.current = index;
        r.turns += 1;
        const clean = force_clean or r.turns % clean_refresh_every == 0;
        const marker = if (clean)
            try r.screen.update(.gc16, .full)
        else
            try r.screen.update(page_waveform, .partial);
        const queued = nowUs();
        try r.screen.waitComplete(marker);
        const done = nowUs();
        if (touched_us) |t| {
            std.debug.print("turn to {d}: touch to queued {d} us, touch to done {d} ms{s}\n", .{
                index + 1, queued -| t, (done -| t) / 1000, if (clean) " (clean)" else "",
            });
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < r.pages.len) _ = try r.ensure(index + 1, index);
        if (index > 0) _ = try r.ensure(index - 1, index);
    }

    fn turn(r: *Reader, delta: i32, touched_us: u64) !void {
        const target = @as(i64, @intCast(r.current)) + delta;
        if (target < 0 or target >= r.pages.len) return;
        try r.show(@intCast(target), touched_us, false);
    }
};

fn loadState(path: [*:0]const u8) text.Pos {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(rc)) return .{};
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [64]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (failed(n)) return .{};
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \n");
    const para = std.fmt.parseInt(usize, it.next() orelse return .{}, 10) catch return .{};
    const byte = std.fmt.parseInt(usize, it.next() orelse return .{}, 10) catch return .{};
    return .{ .para = para, .byte = byte };
}

fn saveState(path: [*:0]const u8, pos: text.Pos) void {
    // Write beside the real file and rename, so a crash can't lose the old position.
    var tmp: [256]u8 = undefined;
    const name = std.mem.sliceTo(path, 0);
    const tmp_len = name.len + 4;
    if (tmp_len >= tmp.len) return;
    @memcpy(tmp[0..name.len], name);
    @memcpy(tmp[name.len..tmp_len], ".tmp");
    tmp[tmp_len] = 0;
    const tmp_path: [*:0]const u8 = @ptrCast(&tmp);

    const rc = linux.open(tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (failed(rc)) return;
    const fd: i32 = @intCast(rc);
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d} {d}\n", .{ pos.para, pos.byte }) catch "";
    const written = linux.write(fd, s.ptr, s.len);
    _ = linux.close(fd);
    if (failed(written) or written != s.len or s.len == 0) return;
    _ = linux.rename(tmp_path, path);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 4) return error.Usage;
    const state_path = argv[3];
    const alloc = std.heap.page_allocator;

    const t0 = nowUs();
    const book = try kfx.parse(alloc, try file.map(argv[1]));
    const ttf = try file.map(argv[2]);
    var screen = try hwtcon.Screen.open();
    var font = try text.Font.init(alloc, ttf, 46, 1.35);
    var footer = try text.Font.init(alloc, ttf, 28, 1.2);
    const layout = text.Layout{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60 };

    // Paginate the whole book so going backwards is exact.
    const geometry = text.Page{ .buf = &.{}, .width = screen.width, .height = screen.height, .stride = screen.stride };
    var pages: std.ArrayList(text.Pos) = .empty;
    var pos = text.Pos{};
    while (pos.para < book.paragraphs.len) {
        try pages.append(alloc, pos);
        const next = try text.layoutPage(&font, null, geometry, book.paragraphs, pos, layout);
        if (next.para == pos.para and next.byte == pos.byte) break;
        pos = next;
    }
    if (pages.items.len == 0) return error.EmptyBook;
    std.debug.print("{d} pages, startup {d} ms\n", .{ pages.items.len, (nowUs() - t0) / 1000 });

    const saved_pos = loadState(state_path);
    var start: usize = 0;
    for (pages.items, 0..) |p, i| {
        if (p.para < saved_pos.para or (p.para == saved_pos.para and p.byte <= saved_pos.byte)) start = i;
    }

    var slots: [3]Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, screen.pixels.len) };

    const touch = try openInput(touch_device);
    const power = try openInput(power_device);
    const x_max = @max(axisMax(touch, eviocgabs_x), 1);
    const y_max = @max(axisMax(touch, eviocgabs_y), 1);

    installSignals();
    const saved_screen = try alloc.alloc(u8, screen.pixels.len);
    @memcpy(saved_screen, screen.pixels);
    defer {
        @memcpy(screen.pixels, saved_screen);
        if (screen.update(.gc16, .full)) |m| {
            screen.waitComplete(m) catch {};
        } else |_| {}
    }

    if (failed(linux.ioctl(touch, eviocgrab, 1))) return error.GrabFailed;
    defer _ = linux.ioctl(touch, eviocgrab, 0);

    var reader = Reader{
        .screen = &screen,
        .font = &font,
        .footer = &footer,
        .book = book,
        .layout = layout,
        .pages = pages.items,
        .slots = slots,
        .current = start,
    };
    try reader.show(start, null, true);

    var fds = [_]linux.pollfd{
        .{ .fd = touch, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = power, .events = linux.POLL.IN, .revents = 0 },
    };
    // The panel reports two touch slots. Every new finger counts, so a resting
    // thumb can't block taps from another finger.
    var slot: usize = 0;
    var xs = [_]i32{ 0, 0 };
    var ys = [_]i32{ 0, 0 };
    var sizes = [_]i32{ 0, 0 };
    var pending_down: ?usize = null;
    var hold_slot: ?usize = null;
    var down_us: u64 = 0;
    var hold_started: ?u64 = null;
    var last_input = nowUs();
    var since_save: u32 = 0;

    defer saveState(state_path, reader.pages[reader.current]);

    while (!stop_requested.load(.acquire)) {
        const wait: i32 = if (hold_started != null) 50 else 1000;
        _ = linux.poll(&fds, fds.len, wait);

        var events: [64]InputEvent = undefined;
        const power_n = linux.read(power, @ptrCast(&events), @sizeOf(@TypeOf(events)));
        if (!failed(power_n) and power_n >= @sizeOf(InputEvent)) {
            for (events[0 .. power_n / @sizeOf(InputEvent)]) |e| {
                if (e.kind == ev_key and e.value == 1) {
                    std.debug.print("quit: power button\n", .{});
                    return;
                }
            }
        }

        const n = linux.read(touch, @ptrCast(&events), @sizeOf(@TypeOf(events)));
        if (!failed(n) and n >= @sizeOf(InputEvent)) {
            last_input = nowUs();
            for (events[0 .. n / @sizeOf(InputEvent)]) |e| {
                if (e.kind == ev_abs and e.code == abs_mt_slot) slot = @min(@as(usize, @intCast(@max(e.value, 0))), 1);
                if (e.kind == ev_abs and e.code == abs_mt_touch_major) sizes[slot] = e.value;
                if (e.kind == ev_abs and e.code == abs_mt_x) xs[slot] = e.value;
                if (e.kind == ev_abs and e.code == abs_mt_y) ys[slot] = e.value;
                if (e.kind == ev_abs and e.code == abs_mt_tracking) {
                    if (e.value >= 0) {
                        pending_down = slot;
                        down_us = @as(u64, e.sec) * 1_000_000 + e.usec;
                    } else if (hold_slot == slot) {
                        hold_slot = null;
                        hold_started = null;
                    }
                }
                // Coordinates of a new touch arrive just before the SYN that ends its packet.
                if (e.kind == 0 and pending_down != null) {
                    const touched = pending_down.?;
                    pending_down = null;
                    const px = @divTrunc(xs[touched] * @as(i32, @intCast(screen.width)), x_max);
                    const py = @divTrunc(ys[touched] * @as(i32, @intCast(screen.height)), y_max);
                    std.debug.print("touch slot {d} at {d},{d} size {d}\n", .{ touched, px, py, sizes[touched] });
                    if (py >= @as(i32, @intCast(screen.height)) - grip_strip_px) {
                        // Resting thumb, not a tap.
                    } else if (px < 200 and py < 200) {
                        hold_started = nowUs();
                        hold_slot = touched;
                    } else {
                        const delta: i32 = if (px < @as(i32, @intCast(screen.width / 3))) -1 else 1;
                        try reader.turn(delta, down_us);
                        since_save += 1;
                        if (since_save >= save_every) {
                            saveState(state_path, reader.pages[reader.current]);
                            since_save = 0;
                        }
                    }
                }
            }
        }

        if (hold_started) |t| {
            if (nowUs() - t >= corner_hold_ms * 1000) {
                std.debug.print("quit: corner hold\n", .{});
                return;
            }
        }
        if (nowUs() - last_input > idle_quit_ms * 1000) {
            std.debug.print("quit: idle\n", .{});
            return;
        }
    }
    std.debug.print("quit: signal\n", .{});
}
