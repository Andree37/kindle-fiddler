//! Renders the quick panel to a PGM image on stdout, so it can be checked by eye.
//! Usage: panelshot <regular.ttf> <bold.ttf> [notes]
const std = @import("std");
const linux = std.os.linux;
const file = @import("file.zig");
const kfx = @import("kfx.zig");
const library = @import("library.zig");
const menu = @import("menu.zig");
const notes = @import("notes.zig");
const system = @import("system.zig");
const text = @import("text.zig");

fn write(data: []const u8) void {
    var at: usize = 0;
    while (at < data.len) {
        const n = linux.write(1, data[at..].ptr, data.len - at);
        if (n > std.math.maxInt(usize) - 4096 or n == 0) break;
        at += n;
    }
}

const filler = "Sample body words stand in for a real page and fill the lines around the marks. ";
const sample = filler ++ filler ++ "One reference2 sits inside a word and a [3] mark stands apart so both shapes can be checked. " ++ filler ++ filler;
const note_line = "This is invented text for checking the note panel, long enough to wrap over several lines. ";
const sample_note = note_line ++ note_line ++ note_line;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const alloc = std.heap.page_allocator;
    const regular = try file.map(argv[1]);
    var title = try text.Font.init(alloc, try file.map(argv[2]), 40, 1.2);
    var small = try text.Font.init(alloc, regular, 30, 1.2);
    const w = 1272;
    const h = 1696;
    const buf = try alloc.alloc(u8, w * h);
    @memset(buf, 0xff);
    const page = text.Page{ .buf = buf, .width = w, .height = h, .stride = w };
    const fonts = library.Fonts{ .title = &title, .small = &small };
    var head_buf: [32]u8 = undefined;

    if (argv.len > 3) {
        var body = try text.Font.init(alloc, regular, 46, 1.35);
        var note_font = try text.Font.init(alloc, regular, 36, 1.3);
        var mark = try text.Font.init(alloc, regular, 28, 1.2);
        const ref1 = std.mem.indexOf(u8, sample, "reference2").? + "reference".len;
        const ref2 = std.mem.indexOf(u8, sample, "[3]").?;
        const links = [_]kfx.Link{ .{ .start = ref1, .end = ref1 + 1, .target = 1 }, .{ .start = ref2, .end = ref2 + 3, .target = 2 } };
        const paras = [_]kfx.Paragraph{
            .{ .text = sample, .style = 0, .links = &links },
            .{ .text = sample_note, .style = 0, .note = true, .note_start = true },
            .{ .text = sample_note, .style = 0, .note = true, .note_start = true },
        };
        _ = try text.renderPage(&body, page, &paras, .{}, .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &mark }, null);
        const parts = [_]kfx.Paragraph{.{ .text = sample_note, .style = 0 }};
        const fitted = try notes.fit(&note_font, &parts, .{}, w, w, null);
        const top = h - fitted.height;
        try notes.render(&note_font, fonts, .{ .buf = buf[top * w..], .width = w, .height = fitted.height, .stride = w }, &parts, .{}, false);
        write(try std.fmt.bufPrint(&head_buf, "P5\n{d} {d}\n255\n", .{ w, h }));
        write(buf);
        return;
    }

    var quick = system.read();
    quick.brightness = 11;
    try menu.render(fonts, page, "A sample book title", true, &quick);
    write(try std.fmt.bufPrint(&head_buf, "P5\n{d} {d}\n255\n", .{ w, menu.height(true) }));
    write(buf[0 .. w * menu.height(true)]);
}
