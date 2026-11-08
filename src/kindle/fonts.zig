//! Where the Kindle keeps its font files. Noface's families map onto these by index.
const settings = @import("../model/settings.zig");

const font_dir = "/usr/java/lib/fonts/";

/// Each family's four files: regular, bold, italic and bold italic.
const faces = [_][4][*:0]const u8{
    .{ font_dir ++ "Amazon-Ember-Regular.ttf", font_dir ++ "Amazon-Ember-Bold.ttf", font_dir ++ "Amazon-Ember-RegularItalic.ttf", font_dir ++ "Amazon-Ember-BoldItalic.ttf" },
    .{ font_dir ++ "Bookerly-Regular.ttf", font_dir ++ "Bookerly-Bold.ttf", font_dir ++ "Bookerly-Italic.ttf", font_dir ++ "Bookerly-BoldItalic.ttf" },
    .{ font_dir ++ "Baskerville-Regular.ttf", font_dir ++ "Baskerville-Bold.ttf", font_dir ++ "Baskerville-Italic.ttf", font_dir ++ "Baskerville-BoldItalic.ttf" },
    .{ font_dir ++ "AmazonEmberSerif_Rg.ttf", font_dir ++ "AmazonEmberSerif_Bd.ttf", font_dir ++ "AmazonEmberSerif_RgIt.ttf", font_dir ++ "AmazonEmberSerif_BdIt.ttf" },
};

comptime {
    if (faces.len != settings.families.len) @compileError("every family needs its font files");
}

/// The file for a family's weight and slant.
pub fn path(family: usize, bold: bool, italic: bool) [*:0]const u8 {
    return faces[family][@as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1];
}
