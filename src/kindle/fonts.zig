//! Where the typefaces' files are: the Kindle's own in its system folder, and the
//! reader's in the fonts folder on the Kindle's drive (the one the Kindle itself reads
//! sideloaded fonts from). Noface's families map onto these by index.
const std = @import("std");
const settings = @import("../model/settings.zig");
const file = @import("../linux/file.zig");
const linux = std.os.linux;

const font_dir = "/usr/java/lib/fonts/";
pub const own_dir = "/mnt/us/fonts";

/// Each family's four files: regular, bold, italic and bold italic.
const faces = [_][4][*:0]const u8{
    .{ font_dir ++ "Amazon-Ember-Regular.ttf", font_dir ++ "Amazon-Ember-Bold.ttf", font_dir ++ "Amazon-Ember-RegularItalic.ttf", font_dir ++ "Amazon-Ember-BoldItalic.ttf" },
    .{ font_dir ++ "Bookerly-Regular.ttf", font_dir ++ "Bookerly-Bold.ttf", font_dir ++ "Bookerly-Italic.ttf", font_dir ++ "Bookerly-BoldItalic.ttf" },
    .{ font_dir ++ "Baskerville-Regular.ttf", font_dir ++ "Baskerville-Bold.ttf", font_dir ++ "Baskerville-Italic.ttf", font_dir ++ "Baskerville-BoldItalic.ttf" },
    .{ font_dir ++ "AmazonEmberSerif_Rg.ttf", font_dir ++ "AmazonEmberSerif_Bd.ttf", font_dir ++ "AmazonEmberSerif_RgIt.ttf", font_dir ++ "AmazonEmberSerif_BdIt.ttf" },
};

comptime {
    if (faces.len != settings.builtin_families.len) @compileError("every family needs its font files");
}

/// The reader's own families' files, found by `findOwn`.
var own: [settings.max_own][4][:0]const u8 = undefined;

/// The file for a family's weight and slant.
pub fn path(family: usize, bold: bool, italic: bool) [*:0]const u8 {
    const which = @as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1;
    if (family < faces.len) return faces[family][which];
    return own[family - faces.len][which];
}

/// What a font file's name says: its family, and which of the four it is (null for
/// weights noface doesn't use, like Light or Medium). "Literata-BoldItalic.ttf" is
/// Literata's bold italic; a name without a style, like "OpenDyslexic.otf", is regular.
pub const Named = struct { family: []const u8, which: ?usize };

pub fn named(file_name: []const u8) ?Named {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    const ext = file_name[dot + 1 ..];
    if (!std.ascii.eqlIgnoreCase(ext, "ttf") and !std.ascii.eqlIgnoreCase(ext, "otf")) return null;
    const stem = file_name[0..dot];
    if (stem.len == 0 or stem[0] == '.') return null; // Hidden, like the Mac's "._" files
    const cut = std.mem.lastIndexOfAny(u8, stem, "-_ ") orelse return .{ .family = stem, .which = 0 };
    const family = stem[0..cut];
    const style = stem[cut + 1 ..];
    const styles = [_]struct { []const u8, ?usize }{
        .{ "Regular", 0 },     .{ "Rg", 0 },          .{ "Roman", 0 },          .{ "Book", 0 },
        .{ "Bold", 1 },        .{ "Bd", 1 },          .{ "Italic", 2 },         .{ "It", 2 },
        .{ "Oblique", 2 },     .{ "RegularItalic", 2 }, .{ "BoldItalic", 3 },   .{ "BdIt", 3 },
        .{ "BoldOblique", 3 }, .{ "Thin", null },     .{ "ExtraLight", null },  .{ "Light", null },
        .{ "Medium", null },   .{ "SemiBold", null }, .{ "ExtraBold", null },   .{ "Black", null },
        .{ "LightItalic", null }, .{ "MediumItalic", null }, .{ "SemiBoldItalic", null }, .{ "ExtraBoldItalic", null },
        .{ "BlackItalic", null }, .{ "ThinItalic", null }, .{ "ExtraLightItalic", null },
    };
    for (styles) |s| {
        if (std.ascii.eqlIgnoreCase(style, s[0])) return if (family.len > 0) .{ .family = family, .which = s[1] } else null;
    }
    return .{ .family = stem, .which = 0 }; // A style it doesn't know is part of the name
}

/// One family's files as found, by which of the four each is.
const Found = struct { name: []const u8, files: [4]?[]const u8 = @splat(null) };

/// Groups file names into families, alphabetically, the first `max` of them.
pub fn group(alloc: std.mem.Allocator, names: []const []const u8, out: []Found) ![]Found {
    var n: usize = 0;
    for (names) |name| {
        const f = named(name) orelse continue;
        const which = f.which orelse continue;
        const at = for (out[0..n], 0..) |g, i| {
            if (std.mem.eql(u8, g.name, f.family)) break i;
        } else blk: {
            if (n == out.len) continue;
            out[n] = .{ .name = try alloc.dupe(u8, f.family) };
            n += 1;
            break :blk n - 1;
        };
        if (out[at].files[which] == null) out[at].files[which] = try alloc.dupe(u8, name);
    }
    std.mem.sort(Found, out[0..n], {}, struct {
        fn less(_: void, x: Found, y: Found) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.less);
    return out[0..n];
}

/// A family's four files, any missing filled from the others: bold italic from bold,
/// italic or regular; the rest from regular, or whichever there is.
pub fn complete(files: [4]?[]const u8) [4][]const u8 {
    const any = files[0] orelse files[1] orelse files[2] orelse files[3].?;
    const regular = files[0] orelse any;
    return .{
        regular,
        files[1] orelse regular,
        files[2] orelse regular,
        files[3] orelse files[1] orelse files[2] orelse regular,
    };
}

/// Finds the reader's own typefaces in the fonts folder and offers them. Files that
/// `usable` turns down (not fonts noface can set text in) are left out. Called once,
/// before the settings are read, so a chosen one is found by name.
pub fn findOwn(alloc: std.mem.Allocator, usable_font: *const fn ([]const u8) bool) void {
    var names_buf: [64][]const u8 = undefined;
    const names = listDir(alloc, own_dir, &names_buf);
    var found_buf: [8]Found = undefined;
    const found = group(alloc, names, &found_buf) catch return;
    var added: usize = 0;
    for (found) |f| {
        if (added == settings.max_own) {
            std.debug.print("fonts: {s} left out, only {d} of your own fit\n", .{ f.name, settings.max_own });
            continue;
        }
        const files = complete(f.files);
        var paths: [4][:0]const u8 = undefined;
        const usable = for (&paths, files) |*p, name| {
            p.* = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ own_dir, name }, 0) catch break false;
            const data = file.map(p.*) catch break false;
            if (!usable_font(data)) break false;
        } else true;
        if (!usable) {
            std.debug.print("fonts: {s} can't be used\n", .{f.name});
            continue;
        }
        if (!settings.addFamily(f.name)) continue;
        own[added] = paths;
        added += 1;
        std.debug.print("fonts: added {s}\n", .{f.name});
    }
}

/// The names of the files in `dir`.
fn listDir(alloc: std.mem.Allocator, dir: [*:0]const u8, out: [][]const u8) [][]const u8 {
    const rc = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (rc > std.math.maxInt(usize) - 4096) return out[0..0];
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    var n: usize = 0;
    while (true) {
        const got = linux.getdents64(fd, &buf, buf.len);
        if (got == 0 or got > std.math.maxInt(usize) - 4096) break;
        var at: usize = 0;
        while (at < got) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (n == out.len) continue;
            out[n] = alloc.dupe(u8, name) catch continue;
            n += 1;
        }
    }
    return out[0..n];
}

test "a font file's name says its family and style" {
    const lit = named("Literata-BoldItalic.ttf").?;
    try std.testing.expectEqualStrings("Literata", lit.family);
    try std.testing.expectEqual(@as(?usize, 3), lit.which);
    try std.testing.expectEqual(@as(?usize, 0), named("OpenDyslexic.otf").?.which);
    try std.testing.expectEqualStrings("OpenDyslexic", named("OpenDyslexic.otf").?.family);
    try std.testing.expectEqual(@as(?usize, null), named("Literata-Light.ttf").?.which);
    try std.testing.expectEqualStrings("Open Sans", named("Open Sans Bold.ttf").?.family);
    try std.testing.expect(named("Readme.txt") == null);
    try std.testing.expect(named("._Literata-Regular.ttf") == null);
    try std.testing.expectEqualStrings("Atkinson-Hyperlegible", named("Atkinson-Hyperlegible.ttf").?.family);
}

test "files group into families, and missing styles borrow from the others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: [4]Found = undefined;
    const got = try group(arena.allocator(), &.{ "Readme.txt", "Literata-Bold.ttf", "Literata-Light.ttf", "Literata-Regular.ttf", "Atkinson.otf" }, &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("Atkinson", got[0].name);
    const lit = complete(got[1].files);
    try std.testing.expectEqualStrings("Literata-Regular.ttf", lit[0]);
    try std.testing.expectEqualStrings("Literata-Bold.ttf", lit[1]);
    try std.testing.expectEqualStrings("Literata-Regular.ttf", lit[2]);
    try std.testing.expectEqualStrings("Literata-Bold.ttf", lit[3]);
}
