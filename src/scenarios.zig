//! noface-scenarios: plays scripted touches through the real app, on a screen in
//! memory and a clock it moves itself, and checks what came of them. Each scenario
//! gets its own folder under /tmp and a generated book, so nothing of the reader's is
//! read or written, and the screen is never touched.
//!
//! Built for Linux: GitHub runs it on every change, and on the Kindle it's the
//! self-test (`noface-scenarios`), done in seconds.
const std = @import("std");
const app = @import("app.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const input_mod = @import("kindle/input.zig");
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const c_memory = @import("gfx/c_memory.zig");
const memory = @import("base/memory.zig");
const catalog = @import("model/catalog.zig");
const settings_model = @import("model/settings.zig");
const state = @import("linux/state.zig");
const os = @import("linux/os.zig");
const reader = @import("screens/reader.zig");
const linux = std.os.linux;

const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
const book_bytes = @embedFile("testdata/scenario.epub");

const Step = input_mod.Step;
const width = 1272;
const height = 1696;

fn tap(x: i32, y: i32) Step {
    return .{ .act = .{ .tap = .{ .x = x, .y = y, .us = 0 } } };
}
fn hold(x: i32, y: i32) Step {
    return .{ .act = .{ .hold = .{ .x = x, .y = y } } };
}
fn swipe(direction: i32) Step {
    return .{ .act = .{ .swipe = direction } };
}
fn wait(ms: u64) Step {
    return .{ .wait_ms = ms };
}
const forward = tap(1000, 900);
const back = tap(150, 900);
const top = tap(636, 60);
const page_middle = tap(636, 1000);

/// What a run left behind, for the checks.
const Outcome = struct { saved: state.State, updates: u32 };

var run_counter: u32 = 0;

/// Opens the scenario book in a fresh app, plays `steps`, and returns what was saved.
fn play(steps: []const Step) !Outcome {
    var budget = memory.Budget{ .name = "scenario", .child = std.heap.smp_allocator, .limit = 256 << 20 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    run_counter += 1;
    var dir_buf: [96]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/noface-scenarios-{d}-{d}", .{ linux.getpid(), run_counter }, 0);
    _ = linux.mkdir(dir, 0o755);
    defer cleanUp(dir);
    var book_path_buf: [128]u8 = undefined;
    const book_path = try std.fmt.bufPrintSentinel(&book_path_buf, "{s}/book.epub", .{dir}, 0);
    try writeFile(book_path, book_bytes);

    os.fake_us = 1_000_000_000;
    defer os.fake_us = null;

    var screen = try hwtcon.Screen.fake(alloc, width, height);
    var script = input_mod.Script{ .steps = steps };
    var input = input_mod.Input{ .touch = -1, .power = -1, .width = width, .height = height, .x_max = width, .y_max = height, .script = &script };

    var body = try Font.init(alloc, go_regular, 46, 1.35);
    var note_font = try Font.init(alloc, go_regular, 36, 1.3);
    var footer = try Font.init(alloc, go_regular, 28, 1.2);
    var reference = try Font.init(alloc, go_regular, 28, 1.2);
    var title = try Font.init(alloc, go_bold, 34, 1.2);
    var small = try Font.init(alloc, go_regular, 34, 1.2);
    var caption = try Font.init(alloc, go_regular, 26, 1.2);
    var hero = try Font.init(alloc, go_bold, 56, 1.2);
    var cover_type = try Font.init(alloc, go_bold, 36, 1.2);
    var slots: [3]app.Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, screen.pixels.len) };

    var paths: [4][160]u8 = undefined;
    const settings_path = try std.fmt.bufPrintSentinel(&paths[0], "{s}/settings", .{dir}, 0);
    const speed_path = try std.fmt.bufPrintSentinel(&paths[1], "{s}/speed", .{dir}, 0);
    const journal_path = try std.fmt.bufPrintSentinel(&paths[2], "{s}/journal", .{dir}, 0);
    const battery_path = try std.fmt.bufPrintSentinel(&paths[3], "{s}/battery", .{dir}, 0);
    var stb_budget = memory.Budget{ .name = "stb", .child = std.heap.smp_allocator, .limit = 128 << 20 };
    c_memory.use(&stb_budget);

    var a = app.App{
        .alloc = alloc,
        .screen = &screen,
        .input = &input,
        .body = &body,
        .note_font = &note_font,
        .footer = &footer,
        .ui = Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type },
        .slots = slots,
        .overlay = try alloc.alloc(u8, screen.pixels.len),
        .lock_saved = try alloc.alloc(u8, screen.pixels.len),
        .lock_cover = try alloc.alloc(u8, screen.pixels.len),
        .state_dir = dir,
        .library_path = "/dev/null",
        .settings_path = settings_path,
        .speed_path = speed_path,
        .journal_path = journal_path,
        .battery_path = battery_path,
        .documents = dir,
        .app_budget = &budget,
        .stb_budget = &stb_budget,
        .settings = .{},
        .utc_offset = 0,
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &reference },
    };
    // Every typeface the settings could pick is the test font: no Kindle fonts needed
    for (&a.face_files) |*family| {
        family[0] = go_regular;
        family[1] = go_bold;
        family[2] = go_regular;
        family[3] = go_bold;
    }
    try a.applySettings();

    var entry = catalog.Entry{ .path = book_path, .title = "Scenario Book", .author = "noface tests", .percent = 0, .last = 0, .kind = "EPUB" };
    _ = try reader.readBook(&a, &entry);

    var state_buf: [320]u8 = undefined;
    return .{ .saved = state.load(try a.statePath(&state_buf, book_path)), .updates = screen.updates };
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (os.failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.CantWrite;
}

/// Removes a scenario's folder and what's in it (one level: it holds only files).
fn cleanUp(dir: [*:0]const u8) void {
    var out: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", dir };
    _ = @import("linux/process.zig").run(&argv, &out);
}

fn samePlace(a: state.State, b: state.State) bool {
    return a.para == b.para and a.byte == b.byte;
}

const Scenario = struct { name: []const u8, run: *const fn () anyerror!void };

const scenarios = [_]Scenario{
    .{ .name = "three pages on and one back is two pages on", .run = struct {
        fn run() !void {
            const there_and_back = try play(&.{ forward, forward, forward, swipe(-1) });
            const two_on = try play(&.{ forward, forward });
            const start = try play(&.{});
            try expect(samePlace(there_and_back.saved, two_on.saved), "the places differ");
            try expect(!samePlace(two_on.saved, start.saved), "turning didn't move the place");
        }
    }.run },
    .{ .name = "going back from the first page stays there", .run = struct {
        fn run() !void {
            const start = try play(&.{});
            const tried = try play(&.{ back, swipe(-1) });
            try expect(samePlace(start.saved, tried.saved), "moved before the first page");
        }
    }.run },
    .{ .name = "a swipe turns like a tap", .run = struct {
        fn run() !void {
            const tapped = try play(&.{forward});
            const swiped = try play(&.{swipe(1)});
            try expect(samePlace(tapped.saved, swiped.saved), "a swipe went somewhere else");
        }
    }.run },
    .{ .name = "reading time counts only while the page shows", .run = struct {
        fn run() !void {
            // A minute on the page, then a minute with the toolbar open
            const r = try play(&.{ wait(60_000), forward, top, wait(60_000), page_middle });
            try expect(r.saved.seconds >= 55 and r.saved.seconds <= 70, "reading time off");
        }
    }.run },
    .{ .name = "common actions on a page run and leave the place alone", .run = struct {
        fn run() !void {
            const plain = try play(&.{forward});
            const busy = try play(&.{
                forward,
                hold(600, 700), tap(636, 300), // A word's definition, closed above the sheet
                top, tap(696, 118), page_middle, // The text settings, closed
                top, tap(816, 118), tap(636, 120), // Contents, closed above it
                top, tap(1176, 118), tap(636, 200), // The menu, closed above the card
                wait(130_000), // Past the Wi-Fi pause
            });
            try expect(samePlace(plain.saved, busy.saved), "the place moved");
            try expect(busy.updates > plain.updates, "nothing was drawn");
        }
    }.run },
};

fn expect(ok: bool, why: []const u8) !void {
    if (!ok) {
        std.debug.print("    {s}\n", .{why});
        return error.ScenarioFailed;
    }
}

/// Wall time, for how long a scenario really took: the app's own clock is the fake one.
fn realMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn main() !void {
    var failed: u32 = 0;
    for (scenarios) |s| {
        const t0 = realMs();
        if (s.run()) {
            std.debug.print("ok    {s} ({d} ms)\n", .{ s.name, realMs() - t0 });
        } else |err| {
            failed += 1;
            std.debug.print("FAIL  {s}: {s}\n", .{ s.name, @errorName(err) });
        }
    }
    std.debug.print("{d} of {d} scenarios passed\n", .{ scenarios.len - failed, scenarios.len });
    if (failed > 0) std.process.exit(1);
}
