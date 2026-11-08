//! The interface fonts every screen draws with.
const text = @import("../book/text.zig");

pub const Fonts = struct {
    title: *text.Font, // UI bold
    small: *text.Font, // UI regular
    caption: *text.Font,
    hero: *text.Font, // Book title, in the reading typeface
    cover: *text.Font,
};
