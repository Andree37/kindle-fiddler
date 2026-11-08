//! Shared by the app and the tools in tools/, which can't reach into src/ directly.

// Amazon: the Kindle's formats, services and hardware.
pub const annotation_db = @import("kindle/annotation_db.zig");
pub const catalog_db = @import("kindle/catalog.zig");
pub const hwtcon = @import("kindle/hwtcon.zig");
pub const ion = @import("kindle/ion.zig");
pub const jpegxr = @import("kindle/jpegxr.zig");
pub const kfx = @import("kindle/kfx.zig");
pub const lipc = @import("kindle/lipc.zig");
pub const safe = @import("kindle/safe.zig");
pub const store = @import("kindle/store.zig");

// Linux.
pub const clock = @import("linux/clock.zig");
pub const file = @import("linux/file.zig");
pub const os = @import("linux/os.zig");
pub const process = @import("linux/process.zig");

// Ours.
pub const book = @import("model/book.zig");
pub const note_rules = @import("model/notes.zig");
pub const catalog = @import("model/catalog.zig");
pub const quick = @import("model/quick.zig");
pub const text = @import("layout/text.zig");
pub const cover = @import("gfx/image.zig");
pub const aa = @import("ui/aa.zig");
pub const fonts = @import("ui/fonts.zig");
pub const goto = @import("ui/goto.zig");
pub const keyboard = @import("ui/keyboard.zig");
pub const library = @import("ui/library.zig");
pub const menu = @import("ui/menu.zig");
pub const notes = @import("ui/notes.zig");
pub const search_ui = @import("ui/search.zig");
pub const sheet = @import("ui/sheet.zig");
pub const toolbar = @import("ui/toolbar.zig");
