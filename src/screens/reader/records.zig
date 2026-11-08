//! Writing and deleting synced records (highlights and bookmarks) for an open book.
const std = @import("std");
const annotations = @import("../../book/annotations.zig");
const catalog = @import("../../book/catalog.zig");
const kfx = @import("../../book/kfx.zig");
const os = @import("../../platform/os.zig");
const system = @import("../../platform/system.zig");
const sess = @import("session.zig");

/// Amazon's position for a place in the text. Null for paragraphs it doesn't number.
pub fn pointFor(s: *sess.Session, para: u32, byte: u32) ?annotations.Point {
    const p = s.paragraphs[para];
    if (p.position == 0) return null;
    const chars = kfx.charOffset(p.text, byte);
    return .{ .element = p.element, .offset = chars, .short = p.position + chars };
}

/// Queues a record for sync. True when it was written (or writes are off for testing).
pub fn write(entry: *const catalog.Entry, kind: annotations.Kind, id: []const u8, start: annotations.Point, end: annotations.Point) bool {
    if (system.dryRun()) return true;
    if (!system.safeId(entry.key) or !system.safeId(entry.kind) or !system.safeId(id) or !system.safeGuid(entry.guid)) return false;
    var buf: [1200]u8 = undefined;
    const sql = annotations.insertSql(&buf, .{
        .kind = kind,
        .id = id,
        .key = entry.key,
        .content_type = entry.kind,
        .guid = entry.guid,
        .start = start,
        .end = end,
        .now_ms = os.unixTime() * 1000,
    }) catch return false;
    return system.runAnnotationSql(sql);
}

/// Queues a record's deletion. True when it was written (or writes are off for testing).
pub fn delete(entry: *const catalog.Entry, kind: annotations.Kind, id: []const u8) bool {
    if (system.dryRun()) return true;
    if (!system.safeId(id) or !system.safeId(entry.key)) return false;
    var buf: [900]u8 = undefined;
    const sql = annotations.deleteSql(&buf, kind, id, entry.key, os.unixTime() * 1000) catch return false;
    return system.runAnnotationSql(sql);
}
