//! Measures how long each e-ink waveform takes for a full-page flip.
//! Saves the current screen first and restores it when done.
const std = @import("std");
const linux = std.os.linux;
const hwtcon = @import("hwtcon.zig");

const Case = struct { name: []const u8, wf: hwtcon.Waveform, mode: hwtcon.UpdateMode };

const cases = [_]Case{
    .{ .name = "GC16 full", .wf = .gc16, .mode = .full },
    .{ .name = "GC16 partial", .wf = .gc16, .mode = .partial },
    .{ .name = "GL16 partial", .wf = .gl16, .mode = .partial },
    .{ .name = "REAGL partial", .wf = .reagl, .mode = .partial },
    .{ .name = "DU4 partial", .wf = .du4, .mode = .partial },
    .{ .name = "DU partial", .wf = .du, .mode = .partial },
    .{ .name = "A2 partial", .wf = .a2, .mode = .partial },
};

const flips = 4;

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Fake page of text: rows of black word-sized blocks on white. `seed` shifts the words.
fn drawPage(buf: []u8, width: u32, height: u32, stride: u32, seed: u32) void {
    @memset(buf, 0xff);
    var y: u32 = 80;
    var line: u32 = seed;
    while (y + 32 < height - 80) : (y += 64) {
        var x: u32 = 80;
        while (x + 40 < width - 80) {
            line = line *% 1103515245 +% 12345;
            const word = 40 + (line >> 16) % 140;
            const end = @min(x + word, width - 80);
            var row = y;
            while (row < y + 32) : (row += 1) {
                @memset(buf[row * stride + x .. row * stride + end], 0x00);
            }
            x = end + 24;
        }
    }
}

pub fn main() !void {
    var screen = try hwtcon.Screen.open();
    std.debug.print("screen {d}x{d} stride {d}\n", .{ screen.width, screen.height, screen.stride });

    const alloc = std.heap.page_allocator;
    const saved = try alloc.alloc(u8, screen.pixels.len);
    const page_a = try alloc.alloc(u8, screen.pixels.len);
    const page_b = try alloc.alloc(u8, screen.pixels.len);
    @memcpy(saved, screen.pixels);
    drawPage(page_a, screen.width, screen.height, screen.stride, 1);
    drawPage(page_b, screen.width, screen.height, screen.stride, 2);

    defer {
        @memcpy(screen.pixels, saved);
        if (screen.update(.gc16, .full)) |m| {
            screen.waitComplete(m) catch {};
        } else |_| {}
    }

    // Blit cost: what a pre-rendered page costs the CPU.
    const b0 = nowUs();
    @memcpy(screen.pixels, page_a);
    std.debug.print("blit {d} us\n", .{nowUs() - b0});
    try screen.waitComplete(try screen.update(.gc16, .full));

    for (cases) |c| {
        var total: u64 = 0;
        var worst: u64 = 0;
        var i: u32 = 0;
        while (i < flips) : (i += 1) {
            @memcpy(screen.pixels, if (i % 2 == 0) page_b else page_a);
            const t0 = nowUs();
            const marker = try screen.update(c.wf, c.mode);
            const queued = nowUs() - t0;
            try screen.waitComplete(marker);
            const dt = nowUs() - t0;
            total += dt;
            worst = @max(worst, dt);
            if (i == 0) std.debug.print("  {s}: queue {d} us\n", .{ c.name, queued });
        }
        std.debug.print("{s}: avg {d} ms, worst {d} ms\n", .{ c.name, total / flips / 1000, worst / 1000 });
    }
}
