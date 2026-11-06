//! Fast reader with its own library screen.
//! Usage: reader <library.tsv> <regular.ttf> <bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Hold the top-left corner for one second to return to the library.
//! In the library, "Kindle" or the power button returns to the stock UI.
const std = @import("std");
const linux = std.os.linux;
const cache = @import("cache.zig");
const file = @import("file.zig");
const hwtcon = @import("hwtcon.zig");
const kfx = @import("kfx.zig");
const library = @import("library.zig");
const state = @import("state.zig");
const text = @import("text.zig");
const touch_zones = @import("touch.zig");

const page_waveform: hwtcon.Waveform = .reagl;
const clean_refresh_every = 20;
const idle_quit_ms = 30 * 60 * 1000;
const corner_hold_ms = 1000;
const save_every = 10;

const touch_device = "/dev/input/event1";
const power_device = "/dev/input/event0";
const eviocgrab: u32 = 0x40044590;
const eviocsclockid: u32 = 0x400445a0;
const eviocgabs_x: u32 = 0x80184540 + 0x35;
const eviocgabs_y: u32 = 0x80184540 + 0x36;

const ev_key = 1;
const ev_abs = 3;
const abs_mt_slot = 0x2f;
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

fn unixTime() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
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
    return @max(info[2], 1);
}

const Action = union(enum) {
    tap: struct { x: i32, y: i32, us: u64 },
    hold,
    power,
    idle,
    stop,
};

/// Turns raw touch events into taps and the corner hold.
/// The panel reports two slots. Every new finger counts, so a resting thumb
/// can't block taps from another finger.
const Input = struct {
    touch: i32,
    power: i32,
    width: i32,
    height: i32,
    x_max: i32,
    y_max: i32,
    events: [64]InputEvent = undefined,
    event_count: usize = 0,
    event_next: usize = 0,
    slot: usize = 0,
    xs: [2]i32 = .{ 0, 0 },
    ys: [2]i32 = .{ 0, 0 },
    pending: ?usize = null,
    down_us: u64 = 0,
    hold_slot: ?usize = null,
    hold_started: ?u64 = null,
    last_input: u64 = 0,

    fn next(in: *Input) Action {
        while (true) {
            if (stop_requested.load(.acquire)) return .stop;
            while (in.event_next < in.event_count) {
                const e = in.events[in.event_next];
                in.event_next += 1;
                if (in.handle(e)) |action| return action;
            }
            if (in.hold_started) |t| {
                if (nowUs() - t >= corner_hold_ms * 1000) {
                    in.hold_started = null;
                    in.hold_slot = null;
                    return .hold;
                }
            }
            if (nowUs() - in.last_input > idle_quit_ms * 1000) return .idle;

            var fds = [_]linux.pollfd{
                .{ .fd = in.touch, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = in.power, .events = linux.POLL.IN, .revents = 0 },
            };
            _ = linux.poll(&fds, fds.len, if (in.hold_started != null) 50 else 1000);

            var power_events: [16]InputEvent = undefined;
            const power_n = linux.read(in.power, @ptrCast(&power_events), @sizeOf(@TypeOf(power_events)));
            if (!failed(power_n) and power_n >= @sizeOf(InputEvent)) {
                for (power_events[0 .. power_n / @sizeOf(InputEvent)]) |e| {
                    if (e.kind == ev_key and e.value == 1) return .power;
                }
            }

            const n = linux.read(in.touch, @ptrCast(&in.events), @sizeOf(@TypeOf(in.events)));
            if (!failed(n) and n >= @sizeOf(InputEvent)) {
                in.event_count = n / @sizeOf(InputEvent);
                in.event_next = 0;
                in.last_input = nowUs();
            }
        }
    }

    fn handle(in: *Input, e: InputEvent) ?Action {
        if (e.kind == ev_abs) {
            switch (e.code) {
                abs_mt_slot => in.slot = @min(@as(usize, @intCast(@max(e.value, 0))), 1),
                abs_mt_x => in.xs[in.slot] = e.value,
                abs_mt_y => in.ys[in.slot] = e.value,
                abs_mt_tracking => {
                    if (e.value >= 0) {
                        in.pending = in.slot;
                        in.down_us = @as(u64, e.sec) * 1_000_000 + e.usec;
                    } else if (in.hold_slot == in.slot) {
                        in.hold_slot = null;
                        in.hold_started = null;
                    }
                },
                else => {},
            }
            return null;
        }
        // Coordinates of a new touch arrive just before the SYN that ends its packet.
        if (e.kind != 0) return null;
        const touched = in.pending orelse return null;
        in.pending = null;
        const px = @divTrunc(in.xs[touched] * in.width, in.x_max);
        const py = @divTrunc(in.ys[touched] * in.height, in.y_max);
        if (touch_zones.isGrip(px, py, in.width, in.height)) return null;
        if (px < 200 and py < 200) {
            in.hold_started = nowUs();
            in.hold_slot = touched;
            return null;
        }
        return .{ .tap = .{ .x = px, .y = py, .us = in.down_us } };
    }
};

const Slot = struct { page: i64 = -1, buf: []u8 };

const App = struct {
    alloc: std.mem.Allocator,
    screen: *hwtcon.Screen,
    input: *Input,
    body: *text.Font,
    footer: *text.Font,
    slots: [3]Slot,
    state_dir: []const u8,
    layout: text.Layout,

    fn page(a: *App, buf: []u8) text.Page {
        return .{ .buf = buf, .width = a.screen.width, .height = a.screen.height, .stride = a.screen.stride };
    }

    /// Inverts part of the screen at once, using the fastest waveform.
    fn flash(a: *App, r: library.Rect) void {
        var row = r.y;
        while (row < r.y + r.h) : (row += 1) {
            const start = row * a.screen.stride + r.x;
            for (a.screen.pixels[start .. start + r.w]) |*p| p.* = ~p.*;
        }
        _ = a.screen.updateRegion(r.x, r.y, r.w, r.h, .du, .partial) catch {};
    }

    fn present(a: *App, buf: []const u8, wf: hwtcon.Waveform, mode: hwtcon.UpdateMode) !void {
        @memcpy(a.screen.pixels, buf);
        try a.screen.waitComplete(try a.screen.update(wf, mode));
    }
};

const Session = struct {
    app: *App,
    paragraphs: []const kfx.Paragraph,
    pages: []const text.Pos,
    current: usize,
    turns: u32 = 0,

    /// Get a rendered page, reusing a cached one when possible.
    fn ensure(s: *Session, index: usize, center: usize) ![]const u8 {
        const a = s.app;
        for (a.slots) |slot| {
            if (slot.page == @as(i64, @intCast(index))) return slot.buf;
        }
        var cached: [3]i64 = undefined;
        for (a.slots, &cached) |slot, *c| c.* = slot.page;
        const victim = cache.victim(cached, @intCast(center));
        const buf = a.slots[victim].buf;
        const page = a.page(buf);
        _ = try text.renderPage(a.body, page, s.paragraphs, s.pages[index], a.layout);

        var label: [32]u8 = undefined;
        const counter = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, s.pages.len }) catch "";
        const x = @as(f32, @floatFromInt(a.screen.width)) / 2 - 50;
        try a.footer.draw(page, x, @intCast(a.screen.height - 60), counter);

        a.slots[victim].page = @intCast(index);
        return buf;
    }

    fn show(s: *Session, index: usize, touched_us: ?u64, force_clean: bool) !void {
        const a = s.app;
        const buf = try s.ensure(index, index);
        @memcpy(a.screen.pixels, buf);
        s.current = index;
        s.turns += 1;
        const clean = force_clean or s.turns % clean_refresh_every == 0;
        const marker = if (clean)
            try a.screen.update(.gc16, .full)
        else
            try a.screen.update(page_waveform, .partial);
        const queued = nowUs();
        try a.screen.waitComplete(marker);
        const done = nowUs();
        if (touched_us) |t| {
            std.debug.print("turn to {d}: touch to queued {d} us, touch to done {d} ms{s}\n", .{
                index + 1, queued -| t, (done -| t) / 1000, if (clean) " (clean)" else "",
            });
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < s.pages.len) _ = try s.ensure(index + 1, index);
        if (index > 0) _ = try s.ensure(index - 1, index);
    }
};

const Outcome = enum { library, quit };

fn saveProgress(entry: *library.Entry, path: [*:0]const u8, s: *const Session) void {
    const pos = s.pages[s.current];
    const percent: u32 = @intCast((s.current + 1) * 100 / s.pages.len);
    const now = unixTime();
    state.save(path, .{ .para = pos.para, .byte = pos.byte, .percent = percent, .opened = now });
    entry.percent = percent;
    entry.last = now;
}

fn readBook(a: *App, entry: *library.Entry) !Outcome {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const t0 = nowUs();
    const data = try file.map(entry.path);
    defer file.unmap(data);
    const book = try kfx.parse(alloc, data);

    // Paginate the whole book so going backwards is exact.
    const geometry = a.page(&.{});
    var pages: std.ArrayList(text.Pos) = .empty;
    var pos = text.Pos{};
    while (pos.para < book.paragraphs.len) {
        try pages.append(alloc, pos);
        const next = try text.layoutPage(a.body, null, geometry, book.paragraphs, pos, a.layout);
        if (next.para == pos.para and next.byte == pos.byte) break;
        pos = next;
    }
    if (pages.items.len == 0) return error.EmptyBook;
    std.debug.print("{d} pages, open {d} ms\n", .{ pages.items.len, (nowUs() - t0) / 1000 });

    var path_buf: [320]u8 = undefined;
    const state_path = try state.pathFor(&path_buf, a.state_dir, entry.path);
    const saved = state.load(state_path);
    var start: usize = 0;
    for (pages.items, 0..) |p, i| {
        if (p.para < saved.para or (p.para == saved.para and p.byte <= saved.byte)) start = i;
    }

    for (&a.slots) |*slot| slot.page = -1;
    var session = Session{ .app = a, .paragraphs = book.paragraphs, .pages = pages.items, .current = start };
    try session.show(start, null, true);
    saveProgress(entry, state_path, &session);

    var since_save: u32 = 0;
    defer saveProgress(entry, state_path, &session);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| {
                const delta: i32 = if (t.x < @divTrunc(a.input.width, 3)) -1 else 1;
                const target = @as(i64, @intCast(session.current)) + delta;
                if (target < 0 or target >= session.pages.len) continue;
                try session.show(@intCast(target), t.us, false);
                since_save += 1;
                if (since_save >= save_every) {
                    saveProgress(entry, state_path, &session);
                    since_save = 0;
                }
            },
            .hold => return .library,
            .power, .idle, .stop => return .quit,
        }
    }
}

fn runLibrary(a: *App, entries: []library.Entry, fonts: library.Fonts) !void {
    const visible = try a.alloc.alloc(usize, entries.len);
    var filter: library.Filter = .all;
    var message: []const u8 = "";
    const buf = a.slots[0].buf;
    a.slots[0].page = -1;

    while (true) {
        library.sort(entries);
        var count = library.select(entries, filter, visible);
        var index: usize = 0;
        const r0 = nowUs();
        try library.render(a.alloc, fonts, a.page(buf), entries, visible[0..count], index, filter, message);
        std.debug.print("library render {d} ms\n", .{(nowUs() - r0) / 1000});
        try a.present(buf, .gc16, .full);
        message = "";

        browse: while (true) {
            switch (a.input.next()) {
                .tap => |t| switch (library.hit(t.x, t.y, a.input.width, index, count)) {
                    .none => continue,
                    .exit => return,
                    .tab => |f| {
                        filter = f;
                        count = library.select(entries, filter, visible);
                        index = 0;
                    },
                    .next => {
                        if (index + 1 >= library.pageCount(count)) continue;
                        index += 1;
                    },
                    .prev => {
                        if (index == 0) continue;
                        index -= 1;
                    },
                    .book => |i| {
                        a.flash(library.rowRect(index, i, a.screen.width));
                        const outcome = readBook(a, &entries[visible[i]]) catch |err| blk: {
                            std.debug.print("could not open book: {s}\n", .{@errorName(err)});
                            message = "This book can't be opened here.";
                            break :blk Outcome.library;
                        };
                        if (outcome == .quit) return;
                        a.slots[0].page = -1;
                        break :browse;
                    },
                },
                .hold => continue,
                .power, .idle, .stop => return,
            }
            try library.render(a.alloc, fonts, a.page(buf), entries, visible[0..count], index, filter, "");
            try a.present(buf, page_waveform, .partial);
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 5) return error.Usage;
    const alloc = std.heap.page_allocator;

    const list = try file.map(argv[1]);
    const entries = try library.parse(alloc, list);
    const state_dir = std.mem.sliceTo(argv[4], 0);
    var path_buf: [320]u8 = undefined;
    for (entries) |*e| {
        const saved = state.load(try state.pathFor(&path_buf, state_dir, e.path));
        if (saved.percent) |p| e.percent = @min(p, 100);
        e.last = @max(e.last, saved.opened);
    }

    const regular = try file.map(argv[2]);
    const bold = try file.map(argv[3]);
    var screen = try hwtcon.Screen.open();
    var body = try text.Font.init(alloc, regular, 46, 1.35);
    var footer = try text.Font.init(alloc, regular, 28, 1.2);
    var title = try text.Font.init(alloc, bold, 40, 1.2);
    var small = try text.Font.init(alloc, regular, 30, 1.2);

    var slots: [3]Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, screen.pixels.len) };

    const touch = try openInput(touch_device);
    const power = try openInput(power_device);
    var input = Input{
        .touch = touch,
        .power = power,
        .width = @intCast(screen.width),
        .height = @intCast(screen.height),
        .x_max = axisMax(touch, eviocgabs_x),
        .y_max = axisMax(touch, eviocgabs_y),
        .last_input = nowUs(),
    };

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

    var app = App{
        .alloc = alloc,
        .screen = &screen,
        .input = &input,
        .body = &body,
        .footer = &footer,
        .slots = slots,
        .state_dir = state_dir,
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60 },
    };
    try runLibrary(&app, entries, .{ .title = &title, .small = &small });
    std.debug.print("quit\n", .{});
}
