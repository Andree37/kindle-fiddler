//! Writes highlights into the Kindle's annotation outbox, in the exact format its
//! own reader uses. Stock's sync service then sends them to Amazon.
const std = @import("std");

/// Amazon's long position: a version byte, element ID and character offset, in base64.
pub fn longPosition(buf: *[12]u8, element: u32, offset: u32) []const u8 {
    var raw: [9]u8 = undefined;
    raw[0] = 1;
    std.mem.writeInt(u32, raw[1..5], element, .little);
    std.mem.writeInt(u32, raw[5..9], offset, .little);
    return std.base64.standard.Encoder.encode(buf, &raw);
}

pub const Point = struct { element: u32, offset: u32, short: u32 };

pub const Highlight = struct {
    id: []const u8,
    key: []const u8,
    kind: []const u8,
    guid: []const u8,
    start: Point,
    end: Point,
    now_ms: u64,
};

/// The statement that queues a highlight for sync.
pub fn insertSql(buf: []u8, h: Highlight) ![]const u8 {
    var start_buf: [12]u8 = undefined;
    var end_buf: [12]u8 = undefined;
    const start = longPosition(&start_buf, h.start.element, h.start.offset);
    const end = longPosition(&end_buf, h.end.element, h.end.offset);
    return std.fmt.bufPrint(buf,
        \\insert or replace into local_edit (annotation_id, action, dataset, dataset_id, serialized_payload, dirty_flag, created_time, modified_time, retry_count, expiration_timestamp) values ('{s}',1,1,'{s}-{s}-{s}-1','{{"book_data":{{"asin":"{s}","contentType":"{s}","guid":"{s}","isOwnedByCustomer":1,"isSample":0}},"created_time":{d},"end_position":{{"longPosition":"{s}","shortPosition":{d}}},"json_metadata":"{{}}","last_modified":{d},"position_type":0,"start_position":{{"longPosition":"{s}","shortPosition":{d}}},"type":"HIGHLIGHT"}}',0,{d},{d},0,'');
    , .{ h.id, h.key, h.kind, h.guid, h.key, h.kind, h.guid, h.now_ms, end, h.end.short, h.now_ms, start, h.start.short, h.now_ms, h.now_ms });
}

/// Removes a row that hasn't been sent yet.
pub fn cancelSql(buf: []u8, id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "delete from local_edit where annotation_id='{s}';", .{id});
}

test "long positions match what the Kindle stores" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("AVAAAADaEQAA", longPosition(&buf, 80, 4570));
    try std.testing.expectEqualStrings("AVAAAABhEgAA", longPosition(&buf, 80, 4705));
}

test "row matches the one the stock reader wrote" {
    var buf: [1024]u8 = undefined;
    const sql = try insertSql(&buf, .{
        .id = "kindle.highlight-381908",
        .key = "0123456789ABCDEF0123456789ABCDEF",
        .kind = "PDOC",
        .guid = "CR!0000000000000000000000000000",
        .start = .{ .element = 80, .offset = 4570, .short = 381908 },
        .end = .{ .element = 80, .offset = 4705, .short = 382043 },
        .now_ms = 1794005896131,
    });
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try std.testing.expect(has(sql, "'kindle.highlight-381908',1,1,'0123456789ABCDEF0123456789ABCDEF-PDOC-CR!0000000000000000000000000000-1'"));
    try std.testing.expect(has(sql, "\"end_position\":{\"longPosition\":\"AVAAAABhEgAA\",\"shortPosition\":382043}"));
    try std.testing.expect(has(sql, "\"start_position\":{\"longPosition\":\"AVAAAADaEQAA\",\"shortPosition\":381908}"));
    try std.testing.expect(has(sql, "\"json_metadata\":\"{}\""));
    try std.testing.expect(has(sql, "\"type\":\"HIGHLIGHT\"}'"));
}
