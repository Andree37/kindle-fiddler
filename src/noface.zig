//! noface: a fast reader with its own home screen.
//! Usage: noface <library.tsv> <body.ttf> <title.ttf> <ui.ttf> <ui-bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Tapping the top of a page opens the toolbar. Dragging down from the top opens
//! the quick panel, in a book or in the library.
//! All Settings or the power button returns to the stock UI.
const std = @import("std");
const linux = std.os.linux;
const cache = @import("cache.zig");
const file = @import("file.zig");
const hwtcon = @import("hwtcon.zig");
const kfx = @import("kfx.zig");
const library = @import("library.zig");
const menu = @import("menu.zig");
const notes = @import("notes.zig");
const book_actions = @import("sheet.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const text = @import("text.zig");
const toolbar = @import("toolbar.zig");
const touch_zones = @import("touch.zig");

const page_waveform: hwtcon.Waveform = .reagl;
const idle_quit_ms = 30 * 60 * 1000;
const save_every = 10;
const download_poll_us = 5 * 1000 * 1000;
const download_watch_us = 3 * 60 * 1000 * 1000;
const clock_check_us = 10 * 1000 * 1000;
const clock_top = 16;
const clock_height = 56;
const clock_width = 160;

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

/// Current position of a multitouch axis in both slots (EVIOCGMTSLOTS).
fn slotValues(fd: i32, code: u32) [2]i32 {
    var request = [_]i32{ @intCast(code), 0, 0 };
    _ = linux.ioctl(fd, 0x800c450a, @intFromPtr(&request));
    return .{ request[1], request[2] };
}

const Action = union(enum) {
    tap: struct { x: i32, y: i32, us: u64 },
    pull,
    drag: i32, // Finger x while a drag is being followed
    drag_end,
    tick,
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
    last_touched: usize = 0,
    grips: bool = true, // Off while controls sit where a thumb usually rests
    tick_us: u64 = 0, // When set, `next` returns .tick this often
    last_tick: u64 = 0,
    drag_slot: ?usize = null,
    last_input: u64 = 0,
    stashed: ?Action = null,

    /// Follows the finger of the last tap until it lifts.
    fn beginDrag(in: *Input) void {
        in.drag_slot = in.last_touched;
    }

    /// Skips to the newest finger position already waiting, if any.
    /// Anything else that turns up is kept for the next call to `next`.
    fn latestDrag(in: *Input) ?i32 {
        var latest: ?i32 = null;
        while (in.stashed == null) {
            while (in.event_next >= in.event_count) {
                const n = linux.read(in.touch, @ptrCast(&in.events), @sizeOf(@TypeOf(in.events)));
                if (failed(n) or n < @sizeOf(InputEvent)) return latest;
                in.event_count = n / @sizeOf(InputEvent);
                in.event_next = 0;
                in.last_input = nowUs();
            }
            const e = in.events[in.event_next];
            in.event_next += 1;
            const action = in.handle(e) orelse continue;
            switch (action) {
                .drag => |x| latest = x,
                else => in.stashed = action,
            }
        }
        return latest;
    }

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
            if (in.tick_us != 0 and nowUs() - in.last_tick >= in.tick_us) {
                in.last_tick = nowUs();
                return .tick;
            }

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
                    } else if (in.drag_slot == in.slot) {
                        in.drag_slot = null;
                        return .drag_end;
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
        if (in.drag_slot) |slot| {
            in.pending = null;
            return .{ .drag = @divTrunc(in.xs[slot] * in.width, in.x_max) };
        }
        if (in.top_slot) |slot| {
            const y = @divTrunc(in.ys[slot] * in.height, in.y_max);
            if (touch_zones.isPull(in.top_y, y)) {
                in.top_slot = null;
                return .pull;
            }
        }
        const touched = in.pending orelse return null;
        in.pending = null;
        in.last_touched = touched;
        const px = @divTrunc(in.xs[touched] * in.width, in.x_max);
        const py = @divTrunc(in.ys[touched] * in.height, in.y_max);
        if (in.grips and touch_zones.isGrip(px, py, in.width, in.height)) return null;
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

const Slot = struct { page: i64 = -1, buf: []u8, hits: text.Hits = .{} };

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
    library_path: [*:0]const u8,
    settings_path: [*:0]const u8,
    settings: menu.Settings,
    quick: system.Quick = .{},
    utc_offset: i64,
    clock_minute: u64 = 0,
    layout: text.Layout,

    /// Notes read smaller than the page, like a printed footnote.
    fn noteFont(a: *App) !*text.Font {
        if (a.body_fonts[0] == null) a.body_fonts[0] = try text.Font.init(a.alloc, a.regular, menu.sizes[0], 1.3);
        a.body_fonts[0].?.line_height = 47;
        return &a.body_fonts[0].?;
    }

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

    /// Writes the time into the page on screen, without refreshing the panel.
    fn stampClock(a: *App) void {
        const target = a.page(a.screen.pixels);
        const left = (a.screen.width - clock_width) / 2;
        target.fillRect(left, clock_top, clock_width, clock_height, 0xff);
        var buf: [8]u8 = undefined;
        const time = system.formatClock(&buf, @intCast(unixTime()), a.utc_offset);
        const width = a.ui.caption.measure(time) catch return;
        const x = @as(f32, @floatFromInt(a.screen.width)) / 2 - width / 2;
        a.ui.caption.draw(target, x, clock_top + 38, time) catch {};
        a.clock_minute = unixTime() / 60;
    }

    /// Redraws just the clock, which is too small to need a flash.
    fn updateClock(a: *App) !void {
        a.stampClock();
        const left = (a.screen.width - clock_width) / 2;
        try a.screen.waitComplete(try a.screen.updateRegion(left, clock_top, clock_width, clock_height, .gl16, .partial));
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
    note_parts: [kfx.max_note_parts]kfx.Paragraph = undefined,
    note_len: usize = 0,
    note_top: u32 = 0,
    note_next: ?text.Pos = null,

    fn referenceAt(s: *Session, x: i32, y: i32) ?u32 {
        for (&s.app.slots) |*slot| {
            if (slot.page == @as(i64, @intCast(s.current))) return slot.hits.find(x, y);
        }
        return null;
    }

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
        a.slots[victim].hits.len = 0;
        _ = try text.renderPage(a.body, page, s.paragraphs, s.pages[index], a.layout, &a.slots[victim].hits);

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
        a.stampClock();
        s.current = index;
        const clean = force_clean;
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
        for (&a.slots) |*slot| {
            if (slot.page != @as(i64, @intCast(index))) continue;
            for (slot.hits.items[0..slot.hits.len]) |h| {
                std.debug.print("ref page {d} at {d},{d} size {d}x{d} target {d}\n", .{ index + 1, h.x, h.y, h.w, h.h, h.target });
            }
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < s.pages.len) _ = try s.ensure(index + 1, index);
        if (index > 0) _ = try s.ensure(index - 1, index);
    }
};

const Outcome = enum { library, quit };
const View = enum { page, toolbar, sheet, panel, note };

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
        const next = try text.layoutPage(a.body, null, geometry, paragraphs, pos, a.layout, null);
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

/// Draws the quick panel over `background` and shows it.
fn drawMenu(a: *App, background: []const u8) !void {
    @memcpy(a.overlay, background);
    try menu.render(a.ui, a.page(a.overlay), &a.quick);
    @memcpy(a.screen.pixels, a.overlay);
    try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, menu.height, page_waveform, .partial));
}

fn closeMenu(a: *App, background: []const u8) !void {
    @memcpy(a.screen.pixels, background);
    try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, menu.height, page_waveform, .partial));
}

/// Draws the toolbar over the current page.
fn drawToolbar(a: *App, s: *Session, title: []const u8, sheet: bool, whole_page: bool) !void {
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    try toolbar.render(a.ui, a.page(a.overlay), title, s.current, s.pages.len, &a.quick, sheet, a.settings);
    @memcpy(a.screen.pixels, a.overlay);
    if (whole_page) {
        try a.screen.waitComplete(try a.screen.updateRegion(0, 0, a.screen.width, a.screen.height, page_waveform, .partial));
        return;
    }
    const top: u32 = if (sheet) toolbar.sheet_height else toolbar.top_height;
    const first = try a.screen.updateRegion(0, 0, a.screen.width, top, page_waveform, .partial);
    try a.screen.waitComplete(try a.screen.updateRegion(0, toolbar.bottom_top, a.screen.width, a.screen.height - toolbar.bottom_top, page_waveform, .partial));
    try a.screen.waitComplete(first);
}

fn closeToolbar(a: *App, s: *Session, sheet: bool) !void {
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    const top: u32 = if (sheet) toolbar.sheet_height else toolbar.top_height;
    const first = try a.screen.updateRegion(0, 0, a.screen.width, top, page_waveform, .partial);
    try a.screen.waitComplete(try a.screen.updateRegion(0, toolbar.bottom_top, a.screen.width, a.screen.height - toolbar.bottom_top, page_waveform, .partial));
    try a.screen.waitComplete(first);
}

/// Follows a finger along the page scrubber, then jumps there.
fn dragScrub(a: *App, s: *Session, title: []const u8, sheet: bool, first_x: i32) !void {
    a.input.beginDrag();
    const screen_page = a.page(a.screen.pixels);
    var target = toolbar.pageAt(first_x, s.pages.len);
    var marker: ?u32 = null;
    const band = a.screen.height - toolbar.scrub_top;
    try toolbar.drawScrub(a.ui, screen_page, target, s.pages.len, true);
    marker = try a.screen.updateRegion(0, toolbar.scrub_top, a.screen.width, band, .a2, .partial);
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |first| {
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const next = toolbar.pageAt(a.input.latestDrag() orelse first, s.pages.len);
                if (next == target) continue;
                target = next;
                try toolbar.drawScrub(a.ui, screen_page, target, s.pages.len, true);
                marker = try a.screen.updateRegion(0, toolbar.scrub_top, a.screen.width, band, .a2, .partial);
            },
            .drag_end => break,
            .tap, .pull, .tick => {},
            .power, .idle, .stop => {
                a.input.stashed = action;
                break;
            },
        }
    }
    if (marker) |m| try a.screen.waitComplete(m);
    s.current = target;
    try drawToolbar(a, s, title, sheet, true);
    try cleanBand(a, toolbar.scrub_top, band);
}

/// Clears everything the fast waveform left behind in a band.
fn cleanBand(a: *App, top: u32, height: u32) !void {
    try a.screen.waitComplete(try a.screen.updateRegion(0, top, a.screen.width, height, .gc16, .full));
}

/// Follows a finger along a text setting, and applies it when lifted.
fn dragSetting(a: *App, alloc: std.mem.Allocator, s: *Session, title: []const u8, row: toolbar.Setting, first_x: i32) !void {
    const is_size = row.hit == .text_size;
    const steps = if (is_size) menu.sizes.len else menu.spacings.len;
    var value = toolbar.stepAt(row, first_x, steps);
    const started = if (is_size) a.settings.size else a.settings.spacing;
    a.input.beginDrag();
    const screen_page = a.page(a.screen.pixels);
    try toolbar.drawSetting(a.ui, screen_page, row, value, steps, true);
    var marker: ?u32 = try a.screen.updateRegion(0, row.top, a.screen.width, toolbar.setting_height, .a2, .partial);
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |first| {
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const next = toolbar.stepAt(row, a.input.latestDrag() orelse first, steps);
                if (next == value) continue;
                value = next;
                try toolbar.drawSetting(a.ui, screen_page, row, value, steps, true);
                marker = try a.screen.updateRegion(0, row.top, a.screen.width, toolbar.setting_height, .a2, .partial);
            },
            .drag_end => break,
            .tap, .pull, .tick => {},
            .power, .idle, .stop => {
                a.input.stashed = action;
                break;
            },
        }
    }
    if (marker) |m| try a.screen.waitComplete(m);
    if (value != started) {
        if (is_size) a.settings.size = value else a.settings.spacing = value;
        try relayout(a, alloc, s);
    }
    try drawToolbar(a, s, title, true, true);
    try cleanBand(a, row.top, toolbar.setting_height);
}

/// Shows a note, or the next part of a long one.
fn showNote(a: *App, s: *Session, start: text.Pos, fixed: ?u32) !void {
    const font = try a.noteFont();
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    const stride = a.screen.stride;
    const fitted = try notes.fit(font, s.note_parts[0..s.note_len], start, a.screen.width, stride, fixed);
    const top = a.screen.height - fitted.height;
    const panel = text.Page{ .buf = a.overlay[top * stride..], .width = a.screen.width, .height = fitted.height, .stride = stride };
    try notes.render(font, a.ui, panel, s.note_parts[0..s.note_len], start, fitted.next != null);
    @memcpy(a.screen.pixels, a.overlay);
    try a.screen.waitComplete(try a.screen.updateRegion(0, top, a.screen.width, fitted.height, page_waveform, .partial));
    s.note_top = top;
    s.note_next = fitted.next;
    std.debug.print("note parts {d} panel {d} more {}\n", .{ s.note_len, fitted.height, fitted.next != null });
}

fn openNote(a: *App, s: *Session, target: u32) !void {
    s.note_len = kfx.noteLength(s.paragraphs, target);
    for (s.paragraphs[target..][0..s.note_len], s.note_parts[0..s.note_len]) |src, *dst| {
        dst.* = src;
        dst.note = false;
        dst.note_start = false;
        dst.links = &.{};
    }
    try showNote(a, s, .{}, null);
}

fn closeNote(a: *App, s: *Session) !void {
    std.debug.print("note closed\n", .{});
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    try a.screen.waitComplete(try a.screen.updateRegion(0, s.note_top, a.screen.width, a.screen.height - s.note_top, page_waveform, .partial));
}

fn rowValue(a: *App, row: menu.Row) u32 {
    return if (row.y == menu.warmth_row.y) a.quick.warmth else a.quick.brightness;
}

fn setRowValue(a: *App, row: menu.Row, level: u32) void {
    if (row.y == menu.warmth_row.y) {
        a.quick.warmth = level;
        system.setWarmth(level, a.quick.schedule);
    } else {
        a.quick.brightness = level;
        system.setBrightness(level);
    }
}

/// Follows a finger along a panel slider until it lifts.
fn dragRow(a: *App, background: []const u8, row: menu.Row) !void {
    a.input.beginDrag();
    const screen_page = a.page(a.screen.pixels);
    var marker: ?u32 = null;
    while (true) {
        const action = a.input.next();
        switch (action) {
            .drag => |first| {
                // One update at a time: overlapping ones smear on the panel.
                if (marker) |m| {
                    try a.screen.waitComplete(m);
                    marker = null;
                }
                const level = menu.levelAt(row, a.input.latestDrag() orelse first);
                if (level == rowValue(a, row)) continue;
                setRowValue(a, row, level);
                try menu.drawSlider(a.ui, screen_page, row, level, true);
                marker = try a.screen.updateRegion(0, menu.bandTop(row), a.screen.width, menu.band_height, .a2, .partial);
            },
            .drag_end => break,
            .tap, .pull, .tick => {},
            .power, .idle, .stop => {
                a.input.stashed = action;
                break;
            },
        }
    }
    if (marker) |m| try a.screen.waitComplete(m);
    try drawMenu(a, background);
    try cleanBand(a, menu.bandTop(row), menu.band_height);
}

/// Runs a panel control. False means the tap wasn't on one.
fn panelControl(a: *App, background: []const u8, choice: menu.Hit, x: i32) !bool {
    if (!applyQuick(a, choice, x)) return false;
    switch (choice) {
        .slider => try dragRow(a, background, menu.brightness_row),
        .warmth => try dragRow(a, background, menu.warmth_row),
        else => try drawMenu(a, background),
    }
    return true;
}

/// Applies a light, warmth or airplane change. False means the tap wasn't one of those.
fn applyQuick(a: *App, change: menu.Hit, x: i32) bool {
    switch (change) {
        .dimmer, .brighter => {
            a.quick.brightness = system.stepBrightness(a.quick.brightness, change == .brighter);
            system.setBrightness(a.quick.brightness);
        },
        .slider => setRowValue(a, menu.brightness_row, menu.levelAt(menu.brightness_row, x)),
        .cooler, .warmer => setRowValue(a, menu.warmth_row, system.stepBrightness(a.quick.warmth, change == .warmer)),
        .warmth => setRowValue(a, menu.warmth_row, menu.levelAt(menu.warmth_row, x)),
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            system.setSchedule(a.quick.schedule);
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
    std.debug.print("open {s}: {d} pages in {d} ms\n", .{ entry.title, pages.len, (nowUs() - t0) / 1000 });

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
    var view: View = .page;
    a.input.grips = true;
    a.input.tick_us = clock_check_us;
    defer a.input.grips = true;
    defer a.input.tick_us = 0;
    defer saveProgress(entry, state_path, &session);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| switch (view) {
                .note => {
                    if (t.y >= session.note_top and session.note_next != null) {
                        try showNote(a, &session, session.note_next.?, a.screen.height - session.note_top);
                    } else {
                        view = .page;
                        try closeNote(a, &session);
                    }
                },
                .panel => {
                    const choice = menu.hit(t.x, t.y);
                    const page = try session.ensure(session.current, session.current);
                    if (try panelControl(a, page, choice, t.x)) continue;
                    switch (choice) {
                        .settings => {
                            system.openSettings();
                            return .quit;
                        },
                        .close => {
                            view = .page;
                            try closeMenu(a, page);
                            try a.updateClock();
                        },
                        else => {},
                    }
                },
                .toolbar, .sheet => {
                    const sheet = view == .sheet;
                    switch (toolbar.hit(t.x, t.y, sheet)) {
                        .stay, .goto, .bookmark, .search, .more => {},
                        .close => {
                            view = .page;
                            a.input.grips = true;
                            try closeToolbar(a, &session, sheet);
                            try a.updateClock();
                        },
                        .home => return .library,
                        .text => {
                            view = if (sheet) .toolbar else .sheet;
                            // Shrinking needs the page back under where the sheet was.
                            try drawToolbar(a, &session, entry.title, view == .sheet, sheet);
                        },
                        .chapter_prev, .chapter_next => |direction| {
                            const sections = try alloc.alloc(u32, session.pages.len);
                            for (session.pages, sections) |p, *out| out.* = session.paragraphs[p.para].section;
                            session.current = toolbar.chapterTarget(sections, session.current, direction == .chapter_next);
                            try drawToolbar(a, &session, entry.title, sheet, true);
                        },
                        .scrub => try dragScrub(a, &session, entry.title, sheet, t.x),
                        .text_size => try dragSetting(a, alloc, &session, entry.title, toolbar.settings[0], t.x),
                        .spacing => try dragSetting(a, alloc, &session, entry.title, toolbar.settings[1], t.x),
                    }
                },
                .page => {
                    if (t.y < touch_zones.top_zone) {
                        view = .toolbar;
                        a.input.grips = false;
                        a.quick = system.read();
                        try drawToolbar(a, &session, entry.title, false, false);
                        continue;
                    }
                    if (session.referenceAt(t.x, t.y)) |target| {
                        view = .note;
                        try openNote(a, &session, target);
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
            },
            .tick => {
                if (view == .page and unixTime() / 60 != a.clock_minute) try a.updateClock();
            },
            .drag, .drag_end => {},
            .pull => {
                if (view != .page) continue;
                view = .panel;
                a.quick = system.read();
                try drawMenu(a, try session.ensure(session.current, session.current));
            },
            .power, .idle, .stop => return .quit,
        }
    }
}

/// The quick panel over the library. Returns true to quit to the stock UI.
fn libraryMenu(a: *App, background: []const u8) !bool {
    a.quick = system.read();
    try drawMenu(a, background);
    while (true) {
        switch (a.input.next()) {
            .tap => |t| {
                const choice = menu.hit(t.x, t.y);
                if (try panelControl(a, background, choice, t.x)) continue;
                switch (choice) {
                    .settings => {
                        system.openSettings();
                        return true;
                    },
                    .close => {
                        try closeMenu(a, background);
                        return false;
                    },
                    else => {},
                }
            },
            .pull, .drag, .drag_end, .tick => {},
            .power, .idle, .stop => return true,
        }
    }
}

fn loggedHit(x: i32, y: i32, index: usize, count: usize) library.Hit {
    const h = library.hit(x, y, index, count);
    std.debug.print("library tap {d},{d}: {s}\n", .{ x, y, @tagName(h) });
    return h;
}

const Library = struct {
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    entries: []library.Entry,
    visible: []usize,

    fn deinit(l: *Library) void {
        l.arena.deinit();
        file.unmap(l.data);
    }

    fn localCount(l: *const Library) usize {
        var n: usize = 0;
        for (l.entries) |e| {
            if (e.isLocal()) n += 1;
        }
        return n;
    }
};

/// The catalog's downloading flag can stay set long after a download ended, so
/// the file decides: a partial book fails to parse.
fn isCompleteBook(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    const data = file.map(path) catch return false;
    defer file.unmap(data);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const book = kfx.parse(arena.allocator(), data) catch return false;
    return book.paragraphs.len > 0;
}

fn loadLibrary(a: *App) !Library {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const data = try file.map(a.library_path);
    const entries = try library.parse(alloc, data);
    var path_buf: [320]u8 = undefined;
    for (entries) |*e| {
        if (e.availability == .downloading and isCompleteBook(e.path)) e.availability = .local;
        if (!e.isLocal()) continue;
        const saved = state.load(try state.pathFor(&path_buf, a.state_dir, e.path));
        if (state.preferKindle(saved, e.kindle_last)) continue;
        if (saved.percent) |p| e.percent = @min(p, 100);
        e.last = @max(e.last, saved.opened);
    }
    return .{ .arena = arena, .data = data, .entries = entries, .visible = try alloc.alloc(usize, entries.len) };
}

/// Shows a book's actions. True means the library changed and should be reloaded.
fn bookSheet(a: *App, e: *library.Entry, background: []const u8) !bool {
    std.debug.print("sheet: {s}\n", .{e.title});
    var confirming = false;
    var list_buf: [3]book_actions.Option = undefined;
    while (true) {
        const list = book_actions.options(e, confirming, &list_buf);
        @memcpy(a.overlay, background);
        try book_actions.render(a.ui, a.page(a.overlay), e, list, confirming);
        @memcpy(a.screen.pixels, a.overlay);
        const area = book_actions.region();
        const top = book_actions.top(list.len) - 8;
        try a.screen.waitComplete(try a.screen.updateRegion(area.x - 8, top, area.w + 16, book_actions.height(list.len) + 16, page_waveform, .partial));

        const chosen: ?book_actions.Option = while (true) {
            switch (a.input.next()) {
                .tap => |t| {
                    const index = book_actions.hit(t.x, t.y, list.len) orelse break null;
                    if (index < list.len) break list[index];
                },
                .power, .idle, .stop => {
                    a.input.stashed = .power;
                    break null;
                },
                else => {},
            }
        };
        switch (chosen orelse .cancel) {
            .cancel => {
                @memcpy(a.screen.pixels, background);
                try a.screen.waitComplete(try a.screen.updateRegion(area.x - 8, top, area.w + 16, book_actions.height(list.len) + 16, page_waveform, .partial));
                return false;
            },
            .remove => confirming = true,
            .confirm_remove => {
                system.removeDownload(e.key, e.kind);
                std.debug.print("removed download: {s}\n", .{e.title});
                return true;
            },
            .download => {
                system.downloadBook(e.key, e.kind);
                std.debug.print("download requested: {s}\n", .{e.title});
                return true;
            },
            .mark_read, .mark_unread => |choice| {
                const done = choice == .mark_read;
                system.markRead(e.key, e.kind, done);
                e.finished = done;
                if (!done and e.percent >= 99) e.percent = 0;
                return true;
            },
        }
    }
}

fn logPage(lib: *const Library, index: usize, count: usize) void {
    const range = library.pageRange(index, count);
    var i = range.first;
    while (i < range.end) : (i += 1) {
        std.debug.print("cell {d} {d} {s}\n", .{ index, i - range.first, lib.entries[lib.visible[i]].title });
    }
}

fn runLibrary(a: *App) !void {
    var lib = try loadLibrary(a);
    defer lib.deinit();
    var filter: library.Filter = .all;
    var order: library.Order = .recent;
    var message: []const u8 = "";
    var index: usize = 0;
    const buf = a.slots[0].buf;
    a.slots[0].page = -1;
    // Set only for a download started here. Catalog flags can stay stuck, so
    // they must never drive this, and checking must never touch the screen.
    var watch_until: u64 = 0;
    defer a.input.tick_us = 0;

    while (true) {
        const alloc = lib.arena.allocator();
        library.sort(lib.entries, order);
        var hero = library.pickHero(lib.entries);
        var count = library.select(lib.entries, filter, hero, lib.visible);
        index = @min(index, library.pageCount(count) - 1);
        a.quick = system.read();
        a.input.tick_us = if (nowUs() < watch_until) download_poll_us else 0;
        const r0 = nowUs();
        try library.render(alloc, a.ui, a.page(buf), lib.entries, hero, lib.visible[0..count], index, filter, order, message, &a.quick);
        std.debug.print("library render {d} ms\n", .{(nowUs() - r0) / 1000});
        try a.present(buf, .gc16, .full);
        logPage(&lib, index, count);
        message = "";

        browse: while (true) {
            var opening: ?*library.Entry = null;
            var acting: ?*library.Entry = null;
            var notice: []const u8 = "";
            switch (a.input.next()) {
                .tap => |t| switch (loggedHit(t.x, t.y, index, count)) {
                    .none => continue,
                    .menu => {
                        if (try libraryMenu(a, buf)) return;
                        continue;
                    },
                    .tab => |f| {
                        filter = f;
                        count = library.select(lib.entries, filter, hero, lib.visible);
                        index = 0;
                    },
                    .sort => {
                        order = order.next();
                        library.sort(lib.entries, order);
                        hero = library.pickHero(lib.entries);
                        count = library.select(lib.entries, filter, hero, lib.visible);
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
                    .hero => {
                        const h = hero orelse continue;
                        a.flash(library.heroRect(a.screen.width));
                        opening = &lib.entries[h];
                    },
                    .hero_dots => acting = &lib.entries[hero orelse continue],
                    .dots => |i| acting = &lib.entries[lib.visible[i]],
                    .book => |i| {
                        const entry = &lib.entries[lib.visible[i]];
                        if (entry.isLocal()) {
                            a.flash(library.bookRect(i, index));
                            opening = entry;
                        } else if (entry.availability == .downloading) {
                            notice = "Still downloading. It will open once it's finished.";
                        } else {
                            notice = "Not on this Kindle yet. Use the three dots to download it.";
                        }
                    },
                },
                .tick => {
                    if (nowUs() >= watch_until) {
                        a.input.tick_us = 0;
                        continue;
                    }
                    system.exportLibrary();
                    var fresh = loadLibrary(a) catch continue;
                    if (fresh.localCount() == lib.localCount()) {
                        fresh.deinit();
                        continue;
                    }
                    lib.deinit();
                    lib = fresh;
                    watch_until = 0;
                    break :browse;
                },
                .drag, .drag_end => continue,
                .pull => {
                    if (try libraryMenu(a, buf)) return;
                    continue;
                },
                .power, .idle, .stop => return,
            }
            if (opening) |entry| {
                a.input.tick_us = 0;
                const outcome = readBook(a, entry) catch |err| blk: {
                    std.debug.print("could not open book: {s}\n", .{@errorName(err)});
                    message = "This book can't be opened here.";
                    break :blk Outcome.library;
                };
                if (outcome == .quit) return;
                a.slots[0].page = -1;
                break :browse;
            }
            if (acting) |entry| {
                const was_cloud = entry.availability == .cloud;
                if (try bookSheet(a, entry, buf)) {
                    if (was_cloud) watch_until = nowUs() + download_watch_us;
                    system.exportLibrary();
                    var fresh = loadLibrary(a) catch break :browse;
                    lib.deinit();
                    lib = fresh;
                    fresh = undefined;
                    break :browse;
                }
                continue;
            }
            try library.render(alloc, a.ui, a.page(buf), lib.entries, hero, lib.visible[0..count], index, filter, order, notice, &a.quick);
            try a.present(buf, .gc16, .partial);
            logPage(&lib, index, count);
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 7) return error.Usage;
    const alloc = std.heap.page_allocator;

    const state_dir = std.mem.sliceTo(argv[6], 0);

    const regular = try file.map(argv[2]);
    const book_bold = try file.map(argv[3]);
    const ui_regular = try file.map(argv[4]);
    const ui_bold = try file.map(argv[5]);
    var screen = try hwtcon.Screen.open();
    var fallback_body = try text.Font.init(alloc, regular, 46, 1.35);
    var footer = try text.Font.init(alloc, regular, 28, 1.2);
    var title = try text.Font.init(alloc, ui_bold, 34, 1.2);
    var small = try text.Font.init(alloc, ui_regular, 34, 1.2);
    var caption = try text.Font.init(alloc, ui_regular, 26, 1.2);
    var hero = try text.Font.init(alloc, book_bold, 56, 1.2);
    var cover_type = try text.Font.init(alloc, book_bold, 36, 1.2);

    var slots: [3]Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, screen.pixels.len) };

    const touch = try openInput(touch_device);
    const power = try openInput(power_device);
    // The kernel only reports coordinates that change, so start from the current ones.
    var input = Input{
        .touch = touch,
        .power = power,
        .width = @intCast(screen.width),
        .height = @intCast(screen.height),
        .x_max = axisMax(touch, eviocgabs_x),
        .y_max = axisMax(touch, eviocgabs_y),
        .xs = slotValues(touch, abs_mt_x),
        .ys = slotValues(touch, abs_mt_y),
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
    const ui = library.Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type };

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
        .library_path = argv[1],
        .settings_path = settings_path,
        .utc_offset = system.utcOffset(),
        .settings = menu.load(settings_path),
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &footer },
    };
    try app.applySettings();
    try runLibrary(&app);
    std.debug.print("quit\n", .{});
}
