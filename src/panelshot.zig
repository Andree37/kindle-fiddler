//! Renders the quick panel to a PGM image on stdout, so it can be checked by eye.
//! Usage: panelshot <regular.ttf> <bold.ttf>
const std = @import("std");
const linux = std.os.linux;
const file = @import("file.zig");
const library = @import("library.zig");
const menu = @import("menu.zig");
const system = @import("system.zig");
const text = @import("text.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const alloc = std.heap.page_allocator;
    var title = try text.Font.init(alloc, try file.map(argv[2]), 40, 1.2);
    var small = try text.Font.init(alloc, try file.map(argv[1]), 30, 1.2);
    const w = 1272;
    const h = 1696;
    const buf = try alloc.alloc(u8, w * h);
    @memset(buf, 0xff);
    var quick = system.read();
    quick.brightness = 11;
    const page = text.Page{ .buf = buf, .width = w, .height = h, .stride = w };
    try menu.render(.{ .title = &title, .small = &small }, page, "A sample book title", true, &quick);

    var header: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&header, "P5\n{d} {d}\n255\n", .{ w, menu.height(true) });
    _ = linux.write(1, head.ptr, head.len);
    var left: usize = w * menu.height(true);
    var at: usize = 0;
    while (left > 0) {
        const n = linux.write(1, buf[at..].ptr, left);
        if (n > std.math.maxInt(usize) - 4096 or n == 0) break;
        at += n;
        left -= n;
    }
}
