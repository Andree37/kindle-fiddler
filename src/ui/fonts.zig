//! The interface fonts every screen draws with.
const Font = @import("../gfx/font.zig").Font;

pub const Fonts = struct {
    title: *Font, // UI bold
    small: *Font, // UI regular
    caption: *Font,
    hero: *Font, // Book title, in the reading typeface
    cover: *Font,
    /// Each typeface's regular at interface size, by family, for showing its name in
    /// itself. Empty, or null for one, where the interface font stands in.
    families: []const ?*Font = &.{},
};
