//! The library catalog: the books on this Kindle and in the cloud, how they sort,
//! filter, and which one leads the home screen. Plain data, no drawing.
const std = @import("std");
const search = @import("search.zig");

pub const Availability = enum { local, cloud, downloading };

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
    finished: bool = false,
    seconds_read: u64 = 0, // Time spent reading it in noface
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

    /// An EPUB copied over the cable, which noface reads itself.
    pub fn isEpub(e: Entry) bool {
        return std.ascii.endsWithIgnoreCase(e.path, ".epub");
    }

    /// On this Kindle and complete, so it can be opened.
    pub fn isLocal(e: Entry) bool {
        return e.availability == .local;
    }
};

pub const Filter = enum { all, unread, read };

const finished_percent = 99;

const untouched_percent = 1; // Stock gives new books 1% without them being opened

pub const Order = enum {
    recent,
    title,
    author,
    added,

    pub fn label(o: Order) []const u8 {
        return switch (o) {
            .recent => "Recent",
            .title => "A to Z",
            .author => "Author",
            .added => "Newest",
        };
    }

    pub fn next(o: Order) Order {
        return switch (o) {
            .recent => .title,
            .title => .author,
            .author => .added,
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
        .author => byAuthor(a, b),
    };
}

/// The name an author sorts under: the part before the comma in "Adams, Douglas",
/// else the last word of "Andy Weir".
pub fn surname(author: []const u8) []const u8 {
    const name = std.mem.trim(u8, author, " ");
    if (std.mem.indexOfScalar(u8, name, ',')) |comma| return std.mem.trim(u8, name[0..comma], " ");
    const space = std.mem.lastIndexOfScalar(u8, name, ' ') orelse return name;
    return name[space + 1 ..];
}

/// By surname, then the rest of the name, then title. Books with no author go last.
fn byAuthor(a: Entry, b: Entry) bool {
    const sa = surname(a.author);
    const sb = surname(b.author);
    if ((sa.len == 0) != (sb.len == 0)) return sb.len == 0;
    if (!std.ascii.eqlIgnoreCase(sa, sb)) return std.ascii.lessThanIgnoreCase(sa, sb);
    if (!std.ascii.eqlIgnoreCase(a.author, b.author)) return std.ascii.lessThanIgnoreCase(a.author, b.author);
    return std.ascii.lessThanIgnoreCase(a.title, b.title);
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

/// Fills `out` with indexes of matching entries, leaving out the hero, and returns how
/// many. A non-empty `query` keeps only books whose title or author has it in.
pub fn select(entries: []const Entry, filter: Filter, hero: ?usize, query: []const u8, out: []usize) usize {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (i == hero) continue;
        if (query.len > 0 and !search.contains(e.title, query) and !search.contains(e.author, query)) continue;
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

test "authors sort by surname, whichever way the name is written" {
    try std.testing.expectEqualStrings("Adams", surname("Adams, Douglas"));
    try std.testing.expectEqualStrings("Weir", surname("Andy Weir"));
    try std.testing.expectEqualStrings("Plato", surname(" Plato "));
    try std.testing.expectEqualStrings("", surname(""));
    var rows = [_]Entry{
        .{ .path = "/a", .title = "Nameless", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "Project Hail Mary", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/c", .title = "Skeleton Crew", .author = "King, Stephen", .percent = 0, .last = 1 },
        .{ .path = "/d", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/e", .title = "Restaurant", .author = "Adams, Douglas", .percent = 0, .last = 1 },
    };
    sort(&rows, .author);
    try std.testing.expectEqualStrings("Restaurant", rows[0].title);
    try std.testing.expectEqualStrings("Skeleton Crew", rows[1].title);
    try std.testing.expectEqualStrings("Artemis", rows[2].title);
    try std.testing.expectEqualStrings("Project Hail Mary", rows[3].title);
    try std.testing.expectEqualStrings("Nameless", rows[4].title);
}

test "sort button cycles" {
    try std.testing.expectEqual(Order.title, Order.recent.next());
    try std.testing.expectEqual(Order.author, Order.title.next());
    try std.testing.expectEqual(Order.added, Order.author.next());
    try std.testing.expectEqual(Order.recent, Order.added.next());
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
    try std.testing.expectEqual(@as(usize, 2), select(&rows, .all, hero, "", &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .unread, hero, "", &out));
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, hero, "", &out));
    try std.testing.expectEqual(@as(usize, 0), out[0]);
}

test "search keeps books whose title or author match" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "Skeleton Crew", .author = "King, Stephen", .percent = 0, .last = 1 },
        .{ .path = "/c", .title = "Project Hail Mary", .author = "Andy Weir", .percent = 100, .last = 1 },
    };
    var out: [3]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), select(&rows, .all, null, "weir", &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .all, null, "SKELETON", &out));
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, null, "weir", &out));
    try std.testing.expectEqual(@as(usize, 0), select(&rows, .all, null, "tolkien", &out));
}

test "with nothing in progress the hero is the latest opened" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Old", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "New", .author = "", .percent = 0, .last = 5 },
    };
    try std.testing.expectEqual(@as(usize, 1), pickHero(&rows).?);
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
