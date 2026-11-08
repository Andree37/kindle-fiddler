//! Shared by the app and the tools in tools/, which can't reach into src/ directly.
pub const aa = @import("ui/aa.zig");
pub const catalog = @import("book/catalog.zig");
pub const goto = @import("ui/goto.zig");
pub const cover = @import("ui/cover.zig");
pub const file = @import("platform/file.zig");
pub const fonts = @import("ui/fonts.zig");
pub const hwtcon = @import("platform/hwtcon.zig");
pub const ion = @import("book/ion.zig");
pub const kfx = @import("book/kfx.zig");
pub const library = @import("ui/library.zig");
pub const menu = @import("ui/menu.zig");
pub const os = @import("platform/os.zig");
pub const notes = @import("ui/notes.zig");
pub const sheet = @import("ui/sheet.zig");
pub const system = @import("platform/system.zig");
pub const text = @import("book/text.zig");
pub const toolbar = @import("ui/toolbar.zig");
