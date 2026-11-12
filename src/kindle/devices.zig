//! Finding the Kindle's hardware at startup instead of assuming one model's: the touch
//! panel, the power button, the battery and the charger, from what Linux says about
//! each device. Kindles name and number these differently from model to model.
const std = @import("std");
const state = @import("../linux/state.zig");

/// Whether bit `bit` is set in a sysfs capability mask: hex words separated by spaces,
/// the most significant first, each as wide as a kernel `long`.
pub fn hasBit(mask: []const u8, bit: usize) bool {
    const word_bits = @bitSizeOf(usize);
    var words: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, mask, " \n");
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    const index = bit / word_bits;
    if (index >= n) return false;
    const word = std.fmt.parseInt(usize, words[n - 1 - index], 16) catch return false;
    return (word >> @intCast(bit % word_bits)) & 1 == 1;
}

const abs_mt_position_x = 0x35;
const key_power = 116;

pub const Input = struct { path: [24]u8 = undefined, len: usize = 0, name: [64]u8 = undefined, name_len: usize = 0 };

fn read(comptime fmt: []const u8, args: anytype, buf: []u8) []const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, fmt, args, 0) catch return "";
    return std.mem.trim(u8, state.readSmall(path, buf), " \n");
}

/// Which kind of input device eventN is: the touch panel reports multitouch positions,
/// a power button reports the power key. Virtual devices that claim every key (as
/// "kindle-input-pt" does) don't count as the button.
fn classify(name: []const u8, abs: []const u8, keys: []const u8) enum { touch, power, other } {
    if (hasBit(abs, abs_mt_position_x)) return .touch;
    if (!hasBit(keys, key_power)) return .other;
    var all_bits = true;
    var words = std.mem.tokenizeAny(u8, keys, " \n");
    while (words.next()) |w| all_bits = all_bits and std.mem.allEqual(u8, w, 'f');
    if (all_bits or std.mem.indexOf(u8, name, "input-pt") != null) return .other;
    return .power;
}

pub const Found = struct { touch: ?u8 = null, power: ?u8 = null };

/// The event numbers of the touch panel and the power button.
pub fn findInputs() Found {
    var found = Found{};
    for (0..16) |i| {
        var name_buf: [96]u8 = undefined;
        var abs_buf: [128]u8 = undefined;
        var key_buf: [512]u8 = undefined;
        const name = read("/sys/class/input/event{d}/device/name", .{i}, &name_buf);
        if (name.len == 0) continue;
        const abs = read("/sys/class/input/event{d}/device/capabilities/abs", .{i}, &abs_buf);
        const keys = read("/sys/class/input/event{d}/device/capabilities/key", .{i}, &key_buf);
        switch (classify(name, abs, keys)) {
            .touch => if (found.touch == null) {
                found.touch = @intCast(i);
            },
            .power => if (found.power == null) {
                found.power = @intCast(i);
            },
            .other => {},
        }
    }
    return found;
}

/// A power supply's role, from its type. USB_WET is a moisture sensor in the port, not
/// a charger, though it says it's online.
pub fn isCharger(kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "USB_WET")) return false;
    return std.mem.startsWith(u8, kind, "USB") or std.mem.eql(u8, kind, "Mains") or std.mem.eql(u8, kind, "Wireless");
}

pub const Power = struct { level: u32, plugged: bool };

/// The battery's level, and whether any charger is plugged in. Null without a battery.
pub fn power() ?Power {
    var names: [12][32]u8 = undefined;
    var lens: [12]usize = undefined;
    const n = listSupplies(&names, &lens);
    var level: ?u32 = null;
    var plugged = false;
    for (names[0..n], lens[0..n]) |*name_buf, len| {
        const name = name_buf[0..len];
        var kind_buf: [32]u8 = undefined;
        var value_buf: [16]u8 = undefined;
        const kind = read("/sys/class/power_supply/{s}/type", .{name}, &kind_buf);
        if (std.mem.eql(u8, kind, "Battery")) {
            if (level == null) level = std.fmt.parseInt(u32, read("/sys/class/power_supply/{s}/capacity", .{name}, &value_buf), 10) catch null;
        } else if (isCharger(kind)) {
            if (std.mem.eql(u8, read("/sys/class/power_supply/{s}/online", .{name}, &value_buf), "1")) plugged = true;
        }
    }
    return .{ .level = level orelse return null, .plugged = plugged };
}

/// The names under /sys/class/power_supply.
fn listSupplies(names: *[12][32]u8, lens: *[12]usize) usize {
    const linux = std.os.linux;
    const rc = linux.open("/sys/class/power_supply", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (rc > std.math.maxInt(usize) - 4096) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [2048]u8 align(8) = undefined;
    var n: usize = 0;
    while (true) {
        const got = linux.getdents64(fd, &buf, buf.len);
        if (got == 0 or got > std.math.maxInt(usize) - 4096) break;
        var at: usize = 0;
        while (at < got) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.' or name.len > 31 or n == names.len) continue;
            @memcpy(names[n][0..name.len], name);
            lens[n] = name.len;
            n += 1;
        }
    }
    return n;
}

test "capability masks read from the right word" {
    // The PW12's touch panel (32-bit words) and power button
    const touch = if (@bitSizeOf(usize) == 32) "2618000 0" else "261800000000000";
    try std.testing.expect(hasBit(touch, abs_mt_position_x));
    try std.testing.expect(!hasBit(touch, 0));
    const pwr = if (@bitSizeOf(usize) == 32) "100000 0 0 0" else "10000000000000 0";
    try std.testing.expect(hasBit(pwr, key_power));
}

test "the touch panel, the power button, and a device that claims every key" {
    const touch = if (@bitSizeOf(usize) == 32) "2618000 0" else "261800000000000";
    const pwr = if (@bitSizeOf(usize) == 32) "100000 0 0 0" else "10000000000000 0";
    try std.testing.expectEqual(.touch, classify("fts_ts", touch, "400 0 0 0 0 0 0 0 0 0 0"));
    try std.testing.expectEqual(.power, classify("bd71828-pwrkey", "0", pwr));
    try std.testing.expectEqual(.other, classify("kindle-input-pt", "0", "ffffffff ffffffff ffffffff ffffffff"));
}

test "a moisture sensor isn't a charger" {
    try std.testing.expect(isCharger("USB_CDP"));
    try std.testing.expect(isCharger("Mains"));
    try std.testing.expect(!isCharger("USB_WET"));
    try std.testing.expect(!isCharger("Battery"));
}
