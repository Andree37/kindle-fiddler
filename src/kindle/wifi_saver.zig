//! Wi-Fi off while reading. The radio is the biggest drain a Kindle has besides the
//! screen, and an open book needs no network. A couple of minutes into a book the
//! Kindle goes into airplane mode, and comes out of it on leaving the book, so the
//! library can sync and download. Airplane mode is the only switch the connection
//! manager doesn't undo: wifid's own "enable" springs back. It's left alone while
//! Bluetooth is on, which airplane mode could cut off.
//!
//! Only a radio noface turned off is turned back on, which a file on the user drive
//! remembers. That way it's put back even after a crash or a reboot: noface.sh does it
//! on the way out, and noface on its way in.
const std = @import("std");
const lipc = @import("lipc.zig");
const state = @import("../linux/state.zig");
const linux = std.os.linux;

/// How long into a book before the radio goes off: a quick look in doesn't toggle it.
pub const after_us: u64 = 2 * 60 * 1000 * 1000;

const marker: [*:0]const u8 = "/mnt/us/noface-data/wifi-paused";

pub const Outcome = enum {
    paused, // Off now
    later, // Not now (a download, Bluetooth, or lipc not answering): try again
    never, // Airplane mode is the reader's own, or noface couldn't note that it acted
};

/// Turns the radio off, if airplane mode and Bluetooth are both off and nothing is
/// downloading. The note goes down first and must be there to read back: without
/// it nothing would ever turn the radio on again.
pub fn pause(downloading: bool) Outcome {
    if (downloading) return .later;
    if (lipc.airplaneOn() orelse return .later) return .never;
    if (lipc.bluetoothOn() orelse return .later) return .later;
    state.writeSmall(marker, "1\n");
    if (!marked()) return .never;
    lipc.setAirplane(true);
    if (lipc.airplaneOn() != true) {
        forget();
        return .later;
    }
    std.debug.print("wifi: off while reading\n", .{});
    return .paused;
}

fn marked() bool {
    var buf: [8]u8 = undefined;
    return state.readSmall(marker, &buf).len > 0;
}

/// Turns the radio back on, if noface is the one that turned it off. The note stays
/// until airplane mode is seen off, so noface.sh or the next start can try again.
pub fn restore() void {
    if (!marked()) return;
    lipc.setAirplane(false);
    if (lipc.airplaneOn() == false) {
        forget();
        std.debug.print("wifi: back on\n", .{});
    } else {
        std.debug.print("wifi: couldn't turn it back on yet\n", .{});
    }
}

/// The reader switched airplane mode themselves: theirs now, not noface's to undo.
pub fn forget() void {
    _ = linux.unlink(marker);
}
