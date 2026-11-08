//! The Kindle's book catalog, exported by device/export.sh into library.tsv.
const std = @import("std");
const process = @import("../linux/process.zig");

/// Rebuilds library.tsv from the catalog.
pub fn exportLibrary() void {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "/mnt/us/noface/export.sh" };
    var out: [16]u8 = undefined;
    _ = process.run(&argv, &out);
}
