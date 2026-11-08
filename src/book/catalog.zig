//! The library catalog: the books on this Kindle and in the cloud, how they sort,
//! filter, and which one leads the home screen. Plain data, no drawing.
const std = @import("std");

pub const Availability = enum { local, cloud, downloading };

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
    finished: bool = false,
    kindle_percent: u32 = 0,
    kindle_last: u64 = 0,
    thumbnail: [:0]const u8 = "",
    added: u64 = 0,
    availability: Availability = .local,
    key: []const u8 = "",
    kind: []const u8 = "",
    guid: []const u8 = "",
    cover: ?[]u8 = null,
    cover_tried: bool = false,
    hero: ?[]u8 = null,
    hero_tried: bool = false,

    pub fn isRead(e: Entry) bool {
        return e.finished or e.percent >= finished_percent;
    }

    /// Started but not finished, which is what the hero leads with.
    pub fn inProgress(e: Entry) bool {
        return !e.isRead() and e.percent > untouched_percent;
    }

    /// On this Kindle and complete, so it can be opened.
    pub fn isLocal(e: Entry) bool {
        return e.availability == .local;
    }
};

pub const Filter = enum { all, unread, read };

const finished_percent = 99;

const untouched_percent = 1; // Stock gives new books 1% without them being opened
const read_state_finished = 2; // Kindle's own "finished" mark

/// Converted filenames look like "Title -- Author -- Year -- junk".
pub fn cleanTitle(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " -- ") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
}

/// Filename conversion turned ":" into "_", and some titles carry a series prefix
/// like "[Bobiverse 01] \u{2022} We Are Legion".
pub fn fixTitle(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var t = cleanTitle(raw);
    const bullet = "\u{2022} ";
    if (t.len > 0 and t[0] == '[') {
        if (std.mem.indexOf(u8, t, bullet)) |at| t = t[at + bullet.len..];
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        if (std.mem.startsWith(u8, t[i..], " _ ")) {
            try out.appendSlice(alloc, ": ");
            i += 3;
        } else if (std.mem.startsWith(u8, t[i..], "_ ")) {
            try out.appendSlice(alloc, ": ");
            i += 2;
        } else {
            try out.append(alloc, t[i]);
            i += 1;
        }
    }
    return std.mem.trimEnd(u8, out.items, "_ ");
}

/// Authors can repeat as "Liu, Cixin [Liu, Cixin]".
pub fn cleanAuthor(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " [") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = fields.next() orelse continue;
        const title = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const percent = std.fmt.parseFloat(f32, fields.next() orelse "0") catch 0;
        const last = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const read_state = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
        const thumbnail = fields.next() orelse "";
        const added = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const availability: Availability = switch (std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0) {
            1 => .cloud,
            2 => .downloading,
            else => .local,
        };
        const key = fields.next() orelse "";
        const kind = fields.next() orelse "";
        const guid = fields.next() orelse "";
        if (path.len == 0 and availability == .local) continue;
        try out.append(alloc, .{
            .path = try alloc.dupeSentinel(u8, path, 0),
            .title = try fixTitle(alloc, title),
            .author = cleanAuthor(author),
            .percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .last = last,
            // The Kindle's own mark, which marking as unread clears.
            .finished = read_state == read_state_finished,
            .kindle_percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .kindle_last = last,
            .thumbnail = try alloc.dupeSentinel(u8, thumbnail, 0),
            .added = added,
            .availability = availability,
            .key = key,
            .kind = kind,
            .guid = guid,
        });
    }
    return out.toOwnedSlice(alloc);
}

pub const Order = enum {
    recent,
    title,
    added,

    pub fn label(o: Order) []const u8 {
        return switch (o) {
            .recent => "Recent",
            .title => "A to Z",
            .added => "Newest",
        };
    }

    pub fn next(o: Order) Order {
        return switch (o) {
            .recent => .title,
            .title => .added,
            .added => .recent,
        };
    }
};

fn before(order: Order, a: Entry, b: Entry) bool {
    // Books on this Kindle always come first: cloud ones can't be opened yet.
    if (a.isLocal() != b.isLocal()) return a.isLocal();
    return switch (order) {
        .recent => a.last > b.last,
        .added => a.added > b.added,
        .title => std.ascii.lessThanIgnoreCase(a.title, b.title),
    };
}

pub fn sort(entries: []Entry, order: Order) void {
    std.mem.sort(Entry, entries, order, before);
}

/// The book for the hero: the latest one in progress, or else the latest opened.
pub fn pickHero(entries: []const Entry) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |e, i| {
        if (!e.inProgress() or !e.isLocal()) continue;
        if (best == null or e.last > entries[best.?].last) best = i;
    }
    if (best != null) return best;
    for (entries, 0..) |e, i| {
        if (!e.isLocal()) continue;
        if (best == null or e.last > entries[best.?].last) best = i;
    }
    return best;
}

/// Fills `out` with indexes of matching entries, leaving out the hero, and returns how many.
pub fn select(entries: []const Entry, filter: Filter, hero: ?usize, out: []usize) usize {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (i == hero) continue;
        const matches = switch (filter) {
            .all => true,
            .read => e.isRead(),
            .unread => !e.isRead(),
        };
        if (matches) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

test "titles lose filename junk" {
    try std.testing.expectEqualStrings("Snow Crash", cleanTitle("Snow Crash -- Stephenson, Neal -- 2010"));
    try std.testing.expectEqualStrings("Prisoners of Geography", cleanTitle("Prisoners of Geography"));
}

test "authors lose repeated names" {
    try std.testing.expectEqualStrings("Liu, Cixin", cleanAuthor("Liu, Cixin [Liu, Cixin]"));
}

test "rows parse and sort newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "/a.kfx\tOld -- x\tA\t12.7\t100\n/b.kfx\tNew\tB\t\t200\n\n";
    const rows = try parse(arena.allocator(), data);
    sort(rows, .recent);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("New", rows[0].title);
    try std.testing.expectEqual(@as(u32, 12), rows[1].percent);
    try std.testing.expectEqualStrings("Old", rows[1].title);
}

test "sort orders by title and by date added" {
    var rows = [_]Entry{
        .{ .path = "/a", .title = "banana", .author = "", .percent = 0, .last = 1, .added = 5 },
        .{ .path = "/b", .title = "Apple", .author = "", .percent = 0, .last = 2, .added = 9 },
        .{ .path = "/c", .title = "cherry", .author = "", .percent = 0, .last = 3, .added = 1 },
    };
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Apple", rows[0].title);
    try std.testing.expectEqualStrings("cherry", rows[2].title);
    sort(&rows, .added);
    try std.testing.expectEqualStrings("Apple", rows[0].title);
    try std.testing.expectEqualStrings("cherry", rows[2].title);
    sort(&rows, .recent);
    try std.testing.expectEqualStrings("cherry", rows[0].title);
}

test "sort button cycles" {
    try std.testing.expectEqual(Order.title, Order.recent.next());
    try std.testing.expectEqual(Order.recent, Order.added.next());
}

test "finished stays read after our progress replaces the percent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "/a\tA\tx\t99.1\t1\t1\n/b\tB\tx\t40\t1\t2\n/c\tC\tx\t40\t1\t1\n/d\tD\tx\t0\t1\t0\n");
    try std.testing.expect(rows[0].isRead());
    rows[0].percent = 3; // Read again from the start, or marked as unread
    try std.testing.expect(!rows[0].isRead());
    try std.testing.expect(rows[1].isRead());
    try std.testing.expect(!rows[2].isRead());
    try std.testing.expect(rows[2].inProgress());
    try std.testing.expect(!rows[3].inProgress());
}

test "hero is the latest book in progress, and leaves the grid" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Done", .author = "", .percent = 99, .last = 3 },
        .{ .path = "/b", .title = "Fresh", .author = "", .percent = 0, .last = 2 },
        .{ .path = "/c", .title = "Now", .author = "", .percent = 34, .last = 1 },
    };
    const hero = pickHero(&rows);
    try std.testing.expectEqual(@as(usize, 2), hero.?);
    var out: [3]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), select(&rows, .all, hero, &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .unread, hero, &out));
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, hero, &out));
    try std.testing.expectEqual(@as(usize, 0), out[0]);
}

test "with nothing in progress the hero is the latest opened" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Old", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "New", .author = "", .percent = 0, .last = 5 },
    };
    try std.testing.expectEqual(@as(usize, 1), pickHero(&rows).?);
}

test "cloud books list without a path and never lead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "\tCloud\tx\t50\t9\t0\t\t1\t1\n/b\tHere\tx\t20\t1\t0\t\t1\t0\n/c\tGetting\tx\t0\t2\t0\t\t1\t2\n\tNoPath\tx\t0\t2\t0\t\t1\t0\n");
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(Availability.cloud, rows[0].availability);
    try std.testing.expectEqual(Availability.downloading, rows[2].availability);
    try std.testing.expectEqual(@as(usize, 1), pickHero(rows).?);
}

test "cloud books sort after local ones" {
    var rows = [_]Entry{
        .{ .path = "", .title = "A cloud book", .author = "", .percent = 0, .last = 9, .availability = .cloud },
        .{ .path = "/b", .title = "Zed", .author = "", .percent = 0, .last = 1 },
    };
    sort(&rows, .recent);
    try std.testing.expectEqualStrings("Zed", rows[0].title);
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Zed", rows[0].title);
}

test "a new book at one percent is not in progress" {
    const fresh = Entry{ .path = "/a", .title = "New", .author = "", .percent = 1, .last = 9 };
    const going = Entry{ .path = "/b", .title = "Going", .author = "", .percent = 2, .last = 1 };
    try std.testing.expect(!fresh.inProgress());
    try std.testing.expect(going.inProgress());
    const rows = [_]Entry{ fresh, going };
    try std.testing.expectEqual(@as(usize, 1), pickHero(&rows).?);
}
