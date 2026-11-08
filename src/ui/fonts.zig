//! The interface fonts every screen draws with.
const Font = @import("../gfx/font.zig").Font;

pub const Fonts = struct {
    title: *Font, // UI bold
    small: *Font, // UI regular
    caption: *Font,
    hero: *Font, // Book title, in the reading typeface
    cover: *Font,
};
