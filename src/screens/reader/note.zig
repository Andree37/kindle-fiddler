//! Notes shown in a panel over the page, from a tapped reference.
const std = @import("std");
const kfx = @import("../../book/kfx.zig");
const notes = @import("../../ui/notes.zig");
const text = @import("../../book/text.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// Shows a note, or the next part of a long one.
pub fn showNote(a: *app.App, s: *sess.Session, start: text.Pos, fixed: ?u32) !void {
    const font = a.note_font;
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    const stride = a.screen.stride;
    const fitted = try notes.fit(font, s.note_parts[0..s.note_len], start, a.screen.width, stride, fixed);
    const top = a.screen.height - fitted.height;
    const panel = text.Page{ .buf = a.overlay[top * stride..], .width = a.screen.width, .height = fitted.height, .stride = stride };
    try notes.render(font, a.ui, panel, s.note_parts[0..s.note_len], start, fitted.next != null);
    @memcpy(a.screen.pixels, a.overlay);
    try a.screen.waitComplete(try a.screen.updateRegion(0, top, a.screen.width, fitted.height, app.page_waveform, .partial));
    s.note_top = top;
    s.note_next = fitted.next;
    std.debug.print("note parts {d} panel {d} more {}\n", .{ s.note_len, fitted.height, fitted.next != null });
}

pub fn openNote(a: *app.App, s: *sess.Session, target: u32) !void {
    s.note_len = kfx.noteLength(s.paragraphs, target);
    for (s.paragraphs[target..][0..s.note_len], s.note_parts[0..s.note_len]) |src, *dst| {
        dst.* = src;
        dst.note = false;
        dst.note_start = false;
        dst.links = &.{};
    }
    try showNote(a, s, .{}, null);
}

pub fn closeNote(a: *app.App, s: *sess.Session) !void {
    std.debug.print("note closed\n", .{});
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    try a.screen.waitComplete(try a.screen.updateRegion(0, s.note_top, a.screen.width, a.screen.height - s.note_top, app.page_waveform, .partial));
}
