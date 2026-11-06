//! Fast reader with its own library screen.
//! Usage: reader <library.tsv> <regular.ttf> <bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Tapping the top of a page, or dragging down from it, opens a bar with Library,
//! Kindle and settings. Dragging down from the top of the library opens Menu.
//! "Kindle" or the power button returns to the stock UI.
const std = @import("std");
const linux = std.os.linux;
const cache = @import("cache.zig");
const file = @import("file.zig");
const hwtcon = @import("hwtcon.zig");
const kfx = @import("kfx.zig");
const library = @import("library.zig");
const menu = @import("menu.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const text = @import("text.zig");
const touch_zones = @import("touch.zig");

const page_waveform: hwtcon.Waveform = .reagl;
const clean_refresh_every = 20;
const clean_refresh_pause_us = 1_000_000; // Never flash while pages are being flicked
const idle_quit_ms = 30 * 60 * 1000;
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
    pull,
    power,
    idle,
    stop,
};

/// Turns raw touch events into taps.
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
    top_slot: ?usize = null,
    top_x: i32 = 0,
    top_y: i32 = 0,
    top_us: u64 = 0,
    last_input: u64 = 0,
    stashed: ?Action = null,

    /// Sums page-turn taps already waiting, so fast tapping jumps instead of lagging.
    /// Anything else that turns up is kept for the next call to `next`.
    fn takeTurns(in: *Input) i32 {
        var delta: i32 = 0;
        while (in.stashed == null) {
            while (in.event_next >= in.event_count) {
                const n = linux.read(in.touch, @ptrCast(&in.events), @sizeOf(@TypeOf(in.events)));
                if (failed(n) or n < @sizeOf(InputEvent)) return delta;
                in.event_count = n / @sizeOf(InputEvent);
                in.event_next = 0;
                in.last_input = nowUs();
            }
            const e = in.events[in.event_next];
            in.event_next += 1;
            const action = in.handle(e) orelse continue;
            switch (action) {
                .tap => |t| {
                    if (t.y < touch_zones.top_zone) {
                        in.stashed = action;
                    } else {
                        delta += turnDirection(t.x, in.width);
                    }
                },
                else => in.stashed = action,
            }
        }
        return delta;
    }

    fn next(in: *Input) Action {
        while (true) {
            if (stop_requested.load(.acquire)) return .stop;
            if (in.stashed) |action| {
                in.stashed = null;
                return action;
            }
            while (in.event_next < in.event_count) {
                const e = in.events[in.event_next];
                in.event_next += 1;
                if (in.handle(e)) |action| return action;
            }
            if (nowUs() - in.last_input > idle_quit_ms * 1000) return .idle;

            var fds = [_]linux.pollfd{
                .{ .fd = in.touch, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = in.power, .events = linux.POLL.IN, .revents = 0 },
            };
            _ = linux.poll(&fds, fds.len, 1000);

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
                    } else if (in.top_slot == in.slot) {
                        // Lifted without dragging, so it was a tap on the top row.
                        in.top_slot = null;
                        return .{ .tap = .{ .x = in.top_x, .y = in.top_y, .us = in.top_us } };
                    }
                },
                else => {},
            }
            return null;
        }
        // Coordinates of a new touch arrive just before the SYN that ends its packet.
        if (e.kind != 0) return null;
        if (in.top_slot) |slot| {
            const y = @divTrunc(in.ys[slot] * in.height, in.y_max);
            if (touch_zones.isPull(in.top_y, y)) {
                in.top_slot = null;
                return .pull;
            }
        }
        const touched = in.pending orelse return null;
        in.pending = null;
        const px = @divTrunc(in.xs[touched] * in.width, in.x_max);
        const py = @divTrunc(in.ys[touched] * in.height, in.y_max);
        if (touch_zones.isGrip(px, py, in.width, in.height)) return null;
        if (py < touch_zones.top_zone) {
            in.top_slot = touched;
            in.top_x = px;
            in.top_y = py;
            in.top_us = in.down_us;
            return null;
        }
        return .{ .tap = .{ .x = px, .y = py, .us = in.down_us } };
    }
};

fn turnDirection(x: i32, width: i32) i32 {
    return if (x < @divTrunc(width, 3)) -1 else 1;
}

const Slot = struct { page: i64 = -1, buf: []u8 };

const App = struct {
    alloc: std.mem.Allocator,
    screen: *hwtcon.Screen,
    input: *Input,
    body: *text.Font,
    body_fonts: [menu.sizes.len]?text.Font = @splat(null),
    regular: []const u8,
    footer: *text.Font,
    ui: library.Fonts,
    slots: [3]Slot,
    overlay: []u8,
    state_dir: []const u8,
    settings_path: [*:0]const u8,
    settings: menu.Settings,
    quick: system.Quick = .{},
    layout: text.Layout,

    /// Fonts are kept per size, so stepping through sizes doesn't reload them.
    fn applySettings(a: *App) !void {
        const slot = &a.body_fonts[a.settings.size];
        if (slot.* == null) slot.* = try text.Font.init(a.alloc, a.regular, a.settings.px(), 1);
        slot.*.?.line_height = a.settings.lineHeight();
        a.body = &slot.*.?;
    }

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
    since_clean: u32 = 0,
    last_turn_us: u64 = 0,

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
        s.since_clean += 1;
        const now = nowUs();
        const paused = now -| s.last_turn_us >= clean_refresh_pause_us;
        s.last_turn_us = now;
        const clean = force_clean or (s.since_clean >= clean_refresh_every and paused);
        if (clean) s.since_clean = 0;
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

/// Lays out the whole book so going backwards is exact.
fn paginate(a: *App, alloc: std.mem.Allocator, paragraphs: []const kfx.Paragraph) ![]const text.Pos {
    const geometry = a.page(&.{});
    var pages: std.ArrayList(text.Pos) = .empty;
    var pos = text.Pos{};
    while (pos.para < paragraphs.len) {
        try pages.append(alloc, pos);
        const next = try text.layoutPage(a.body, null, geometry, paragraphs, pos, a.layout);
        if (next.para == pos.para and next.byte == pos.byte) break;
        pos = next;
    }
    return pages.items;
}

fn pageContaining(pages: []const text.Pos, para: usize, byte: usize) usize {
    var found: usize = 0;
    for (pages, 0..) |p, i| {
        if (p.para < para or (p.para == para and p.byte <= byte)) found = i;
    }
    return found;
}

/// Draws the bar over `background` and shows it.
fn drawMenu(a: *App, background: []const u8, title: []const u8, in_book: bool, whole_page: bool) !void {
    @memcpy(a.overlay, background);
    try menu.render(a.ui, a.page(a.overlay), title, in_book, a.quick);
    @memcpy(a.screen.pixels, a.overlay);
    const h: u32 = if (whole_page) a.screen.height else menu.height(in_book);
    try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, h, page_waveform, .partial));
}

fn closeMenu(a: *App, background: []const u8, in_book: bool) !void {
    @memcpy(a.screen.pixels, background);
    try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, menu.height(in_book), page_waveform, .partial));
}

/// Applies a light or airplane change. False means the tap wasn't one of those.
fn applyQuick(a: *App, change: menu.Hit) bool {
    switch (change) {
        .dimmer, .brighter => {
            a.quick.brightness = system.stepBrightness(a.quick.brightness, change == .brighter);
            system.setBrightness(a.quick.brightness);
        },
        .airplane => {
            a.quick.airplane = !a.quick.airplane;
            system.setAirplane(a.quick.airplane);
        },
        else => return false,
    }
    return true;
}

/// Re-lays out the book after a text setting changed, keeping the reading position.
fn relayout(a: *App, alloc: std.mem.Allocator, s: *Session) !void {
    const pos = s.pages[s.current];
    menu.save(a.settings_path, a.settings);
    try a.applySettings();
    for (&a.slots) |*slot| slot.page = -1;
    s.pages = try paginate(a, alloc, s.paragraphs);
    s.current = pageContaining(s.pages, pos.para, pos.byte);
}

fn readBook(a: *App, entry: *library.Entry) !Outcome {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const t0 = nowUs();
    const data = try file.map(entry.path);
    defer file.unmap(data);
    const book = try kfx.parse(alloc, data);

    const pages = try paginate(a, alloc, book.paragraphs);
    if (pages.len == 0) return error.EmptyBook;
    std.debug.print("{d} pages, open {d} ms\n", .{ pages.len, (nowUs() - t0) / 1000 });

    var path_buf: [320]u8 = undefined;
    const state_path = try state.pathFor(&path_buf, a.state_dir, entry.path);
    const saved = state.load(state_path);
    const start = if (state.preferKindle(saved, entry.kindle_last))
        @min(pages.len * entry.kindle_percent / 100, pages.len - 1)
    else
        pageContaining(pages, saved.para, saved.byte);

    for (&a.slots) |*slot| slot.page = -1;
    var session = Session{ .app = a, .paragraphs = book.paragraphs, .pages = pages, .current = start };
    try session.show(start, null, true);
    saveProgress(entry, state_path, &session);

    var since_save: u32 = 0;
    var menu_open = false;
    defer saveProgress(entry, state_path, &session);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| {
                if (menu_open) {
                    const choice = menu.hit(t.x, t.y, a.input.width, true);
                    if (applyQuick(a, choice)) {
                        try drawMenu(a, try session.ensure(session.current, session.current), entry.title, true, false);
                        continue;
                    }
                    switch (choice) {
                        .none, .dimmer, .brighter, .airplane => {},
                        .library => return .library,
                        .kindle => return .quit,
                        .close => {
                            menu_open = false;
                            try closeMenu(a, try session.ensure(session.current, session.current), true);
                        },
                        .smaller, .larger, .tighter, .looser => |change| {
                            var next = a.settings;
                            switch (change) {
                                .smaller => next.size = menu.step(next.size, -1, menu.sizes.len),
                                .larger => next.size = menu.step(next.size, 1, menu.sizes.len),
                                .tighter => next.spacing = menu.step(next.spacing, -1, menu.spacings.len),
                                else => next.spacing = menu.step(next.spacing, 1, menu.spacings.len),
                            }
                            if (std.meta.eql(next, a.settings)) continue;
                            a.settings = next;
                            try relayout(a, alloc, &session);
                            try drawMenu(a, try session.ensure(session.current, session.current), entry.title, true, true);
                        },
                    }
                    continue;
                }
                if (t.y < touch_zones.top_zone) {
                    menu_open = true;
                    a.quick = system.read();
                    try drawMenu(a, try session.ensure(session.current, session.current), entry.title, true, false);
                    continue;
                }
                const delta = turnDirection(t.x, a.input.width) + a.input.takeTurns();
                const last: i64 = @intCast(session.pages.len - 1);
                const target = std.math.clamp(@as(i64, @intCast(session.current)) + delta, 0, last);
                if (target == session.current) continue;
                try session.show(@intCast(target), t.us, false);
                since_save += 1;
                if (since_save >= save_every) {
                    saveProgress(entry, state_path, &session);
                    since_save = 0;
                }
            },
            .pull => {
                if (menu_open) continue;
                menu_open = true;
                a.quick = system.read();
                try drawMenu(a, try session.ensure(session.current, session.current), entry.title, true, false);
            },
            .power, .idle, .stop => return .quit,
        }
    }
}

/// The bar over the library. Returns true to quit to the stock UI.
fn libraryMenu(a: *App, background: []const u8) !bool {
    a.quick = system.read();
    try drawMenu(a, background, "", false, false);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| {
                const choice = menu.hit(t.x, t.y, a.input.width, false);
                if (applyQuick(a, choice)) {
                    try drawMenu(a, background, "", false, false);
                    continue;
                }
                switch (choice) {
                    .kindle => return true,
                    .close, .library => {
                        try closeMenu(a, background, false);
                        return false;
                    },
                    else => {},
                }
            },
            .pull => {},
            .power, .idle, .stop => return true,
        }
    }
}

fn runLibrary(a: *App, entries: []library.Entry, fonts: library.Fonts) !void {
    const visible = try a.alloc.alloc(usize, entries.len);
    var filter: library.Filter = .all;
    var order: library.Order = .recent;
    var message: []const u8 = "";
    const buf = a.slots[0].buf;
    a.slots[0].page = -1;

    while (true) {
        library.sort(entries, order);
        var count = library.select(entries, filter, visible);
        var index: usize = 0;
        const r0 = nowUs();
        try library.render(a.alloc, fonts, a.page(buf), entries, visible[0..count], index, filter, order, message);
        std.debug.print("library render {d} ms\n", .{(nowUs() - r0) / 1000});
        try a.present(buf, .gc16, .full);
        message = "";

        browse: while (true) {
            switch (a.input.next()) {
                .tap => |t| switch (library.hit(t.x, t.y, a.input.width, index, count)) {
                    .none => continue,
                    .exit => return,
                    .menu => {
                        if (try libraryMenu(a, buf)) return;
                        continue;
                    },
                    .tab => |f| {
                        filter = f;
                        count = library.select(entries, filter, visible);
                        index = 0;
                    },
                    .sort => {
                        order = order.next();
                        library.sort(entries, order);
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
                .pull => {
                    if (try libraryMenu(a, buf)) return;
                    continue;
                },
                .power, .idle, .stop => return,
            }
            try library.render(a.alloc, fonts, a.page(buf), entries, visible[0..count], index, filter, order, "");
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
        if (state.preferKindle(saved, e.kindle_last)) continue;
        if (saved.percent) |p| e.percent = @min(p, 100);
        e.last = @max(e.last, saved.opened);
    }

    const regular = try file.map(argv[2]);
    const bold = try file.map(argv[3]);
    var screen = try hwtcon.Screen.open();
    var fallback_body = try text.Font.init(alloc, regular, 46, 1.35);
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

    var settings_buf: [320]u8 = undefined;
    const settings_path = try std.fmt.bufPrintSentinel(&settings_buf, "{s}/settings", .{state_dir}, 0);
    const ui = library.Fonts{ .title = &title, .small = &small };

    var app = App{
        .alloc = alloc,
        .screen = &screen,
        .input = &input,
        .body = &fallback_body,
        .regular = regular,
        .footer = &footer,
        .ui = ui,
        .slots = slots,
        .overlay = try alloc.alloc(u8, screen.pixels.len),
        .state_dir = state_dir,
        .settings_path = settings_path,
        .settings = menu.load(settings_path),
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60 },
    };
    try app.applySettings();
    try runLibrary(&app, entries, ui);
    std.debug.print("quit\n", .{});
}
