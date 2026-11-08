//! Renders the quick panel to a PGM image on stdout, so it can be checked by eye.
//! Usage: panelshot [panel | notes | toolbar [sheet] | library [page [read]]]
const std = @import("std");
const catalog = core.catalog;
const Fonts = core.fonts.Fonts;
const core = @import("core");
const linux = std.os.linux;
const cover = core.cover;
const file = core.file;
const kfx = core.kfx;
const library = core.library;
const menu = core.menu;
const notes = core.notes;
const sheet = core.sheet;
const system = core.system;
const text = core.text;
const toolbar = core.toolbar;

/// Writes a grayscale screen to stdout as a PGM image.
fn writeImage(pixels: []const u8, w: usize, h: usize) void {
    var head: [32]u8 = undefined;
    write(std.fmt.bufPrint(&head, "P5\n{d} {d}\n255\n", .{ w, h }) catch return);
    write(pixels);
}

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
    const dir = "/usr/java/lib/fonts/";
    const regular = try file.map(dir ++ "Bookerly-Regular.ttf");
    const book_bold = try file.map(dir ++ "Bookerly-Bold.ttf");
    const ui_regular = try file.map(dir ++ "Amazon-Ember-Regular.ttf");
    const ui_bold = try file.map(dir ++ "Amazon-Ember-Bold.ttf");
    var title = try text.Font.init(alloc, ui_bold, 34, 1.2);
    var small = try text.Font.init(alloc, ui_regular, 34, 1.2);
    var caption = try text.Font.init(alloc, ui_regular, 26, 1.2);
    var hero = try text.Font.init(alloc, book_bold, 56, 1.2);
    var cover_type = try text.Font.init(alloc, book_bold, 36, 1.2);
    const fonts = Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type };
    const w = 1272;
    const h = 1696;
    const buf = try alloc.alloc(u8, w * h);
    @memset(buf, 0xff);
    const page = text.Page{ .buf = buf, .width = w, .height = h, .stride = w };
    const mode = if (argv.len > 1) std.mem.sliceTo(argv[1], 0) else "panel";
    var quick = system.read(.{});

    if (std.mem.eql(u8, mode, "library")) {
        const entries = try catalog.parse(alloc, try file.map("/mnt/us/noface/library.tsv"));
        catalog.sort(entries, .recent);
        const visible = try alloc.alloc(usize, entries.len);
        const filter: catalog.Filter = if (argv.len > 3) .read else .all;
        const lead = catalog.pickHero(entries);
        const count = catalog.select(entries, filter, lead, visible);
        const index: usize = if (argv.len > 2) try std.fmt.parseInt(usize, std.mem.sliceTo(argv[2], 0), 10) else 0;
        try library.render(alloc, fonts, page, entries, lead, visible[0..count], index, filter, .recent, "", &quick);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "notes")) {
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
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "sheet")) {
        const entries = try catalog.parse(alloc, try file.map("/mnt/us/noface/library.tsv"));
        catalog.sort(entries, .recent);
        const lead = catalog.pickHero(entries);
        const visible = try alloc.alloc(usize, entries.len);
        const count = catalog.select(entries, .all, lead, visible);
        try library.render(alloc, fonts, page, entries, lead, visible[0..count], 0, .all, .recent, "", &quick);
        var list: [3]sheet.Option = undefined;
        const confirming = argv.len > 2;
        const opts = sheet.options(&entries[visible[0]], confirming, &list);
        try sheet.render(fonts, page, &entries[visible[0]], opts, confirming);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "lock")) {
        const data = try file.map(argv[2]);
        const jpeg = kfx.coverImage(data) orelse return error.NoCover;
        std.debug.print("jpeg {d} bytes\n", .{jpeg.len});
        if (!cover.fillScreen(alloc, jpeg, buf, w, h, w)) return error.DecodeFailed;
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "contents")) {
        // Invented titles, nested the way books do.
        const names = [_][]const u8{ "Cover", "Part One", "A first chapter title", "A second chapter", "Interlude", "A much longer chapter title that has to be clipped at the edge of the page", "Part Two", "Short", "Another chapter", "Notes" };
        var list: [24]core.kfx.Chapter = undefined;
        var page_of: [24]usize = undefined;
        for (&list, &page_of, 0..) |*c, *p, i| {
            c.* = .{ .title = names[i % names.len], .para = @intCast(i * 10), .depth = if (i % 5 == 2 or i % 5 == 3) 1 else 0 };
            p.* = i * 17;
        }
        @memset(buf, 0xe8);
        try toolbar.render(fonts, page, "A sample book title", 36, 280, &quick, null, .{});
        try core.contents.render(fonts, page, &list, &page_of, 3, 0);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "toolbar")) {
        const tab: ?core.aa.Tab = if (argv.len > 2) @enumFromInt(argv[2][0] - '0') else null;
        @memset(buf, 0xe8);
        try toolbar.render(fonts, page, "A sample book title", 36, 280, &quick, tab, .{});
        writeImage(buf, w, h);
        return;
    }

    quick.brightness = 11;
    try menu.render(fonts, page, &quick);
    writeImage(buf[0 .. w * menu.height], w, menu.height);
}
