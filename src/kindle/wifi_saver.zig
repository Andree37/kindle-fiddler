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

const marker: [*:0]const u8 = "/mnt/us/noface/wifi-paused";

/// Turns the radio off, if airplane mode and Bluetooth are both off. True when it did.
pub fn pause() bool {
    if (lipc.airplaneOn() orelse true) return false; // On already: the reader's choice
    if (lipc.bluetoothOn() orelse true) return false;
    state.writeSmall(marker, "1\n");
    lipc.setAirplane(true);
    std.debug.print("wifi: off while reading\n", .{});
    return true;
}

/// Turns the radio back on, if noface is the one that turned it off.
pub fn restore() void {
    var buf: [8]u8 = undefined;
    if (state.readSmall(marker, &buf).len == 0) return;
    lipc.setAirplane(false);
    forget();
    std.debug.print("wifi: back on\n", .{});
}

/// The reader switched airplane mode themselves: theirs now, not noface's to undo.
pub fn forget() void {
    _ = linux.unlink(marker);
}
