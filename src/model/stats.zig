//! Reading statistics: how fast this reader reads, and so how long is left.
//! Modelled on the Kindle's own reading timer: one words-per-minute sample per page
//! read forward, kept as a running mean and spread, with improbable pages left out.
const std = @import("std");

pub const max_page_seconds = 300; // Longer than this, the reader stepped away: not reading

const min_wpm = 40; // Slower: the reader looked away. Same bounds as the Kindle's.
const max_wpm = 900; // Faster: flicking past
const skim_wpm = 500; // Reading and skimming fall either side of this
const min_page_words = 20; // Fewer words (a title page, a picture) says little about speed
const pages_to_learn = 5; // Samples before estimates are shown
const pages_for_outliers = 10; // Samples before a page can be judged improbable

/// This reader's speed in words per minute, over every book.
pub const Speed = struct {
    pages: u32 = 0, // Pages counted
    mean: f64 = 0, // Words per minute
    m2: f64 = 0, // Sum of squared differences from the mean (Welford)

    /// Counts one page read forward, unless it doesn't look like reading.
    pub fn record(s: *Speed, words: u64, us: u64) void {
        if (words < min_page_words or us == 0) return;
        const wpm = @as(f64, @floatFromInt(words)) * 60e6 / @as(f64, @floatFromInt(us));
        if (wpm < min_wpm or wpm > max_wpm) return;
        if (s.known() and (s.mean <= skim_wpm) != (wpm <= skim_wpm)) return; // Skimming, or a slow patch
        if (s.pages >= pages_for_outliers and s.improbable(wpm)) return;
        s.pages += 1;
        const delta = wpm - s.mean;
        s.mean += delta / @as(f64, @floatFromInt(s.pages));
        s.m2 += delta * (wpm - s.mean);
    }

    /// Enough pages to give honest estimates.
    pub fn known(s: Speed) bool {
        return s.pages >= pages_to_learn and s.mean > 0;
    }

    fn spread(s: Speed) f64 {
        if (s.pages < 2) return 0;
        return @sqrt(s.m2 / @as(f64, @floatFromInt(s.pages - 1)));
    }

    /// Chauvenet's criterion, as the Kindle uses: a page so far from the usual speed
    /// that fewer than half a page in all of them would be expected to read like it.
    fn improbable(s: Speed, wpm: f64) bool {
        const sd = s.spread();
        if (sd == 0) return false;
        const z = @abs(wpm - s.mean) / sd;
        return erfc(z / std.math.sqrt2) * @as(f64, @floatFromInt(s.pages)) < 0.5;
    }

    /// Minutes to read `words` more, rounded up. Null while still learning.
    pub fn minutesFor(s: Speed, words: u64) ?u64 {
        if (!s.known()) return null;
        return @intFromFloat(@ceil(@as(f64, @floatFromInt(words)) / s.mean));
    }
};

/// Complementary error function, Abramowitz and Stegun 7.1.26 (error below 1.5e-7).
fn erfc(x: f64) f64 {
    const t = 1 / (1 + 0.3275911 * x);
    const poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
    return poly * @exp(-x * x);
}

/// Words in some text: runs of anything but spaces.
pub fn countWords(text: []const u8) u64 {
    var n: u64 = 0;
    var in_word = false;
    for (text) |c| {
        const space = c == ' ' or c == '\n' or c == '\t';
        if (!space and !in_word) n += 1;
        in_word = !space;
    }
    return n;
}

/// Time counted toward a book: the time on a page, unless it was left open.
pub fn countedSeconds(seconds: u64) u64 {
    return if (seconds > max_page_seconds) 0 else seconds;
}

/// "12 min", "1 h 5 min", "3 h".
pub fn formatMinutes(buf: []u8, minutes: u64) []const u8 {
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d} min", .{@max(minutes, 1)}) catch "";
    const h = minutes / 60;
    const m = minutes % 60;
    if (m == 0) return std.fmt.bufPrint(buf, "{d} h", .{h}) catch "";
    return std.fmt.bufPrint(buf, "{d} h {d} min", .{ h, m }) catch "";
}

const format_tag = "wpm";

pub fn parse(content: []const u8) Speed {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    // Older files counted bytes and seconds; that speed starts over.
    if (!std.mem.eql(u8, it.next() orelse return .{}, format_tag)) return .{};
    const pages = std.fmt.parseInt(u32, it.next() orelse return .{}, 10) catch return .{};
    const mean = std.fmt.parseFloat(f64, it.next() orelse return .{}) catch return .{};
    const m2 = std.fmt.parseFloat(f64, it.next() orelse return .{}) catch return .{};
    if (!(mean >= 0 and mean <= max_wpm and m2 >= 0)) return .{};
    return .{ .pages = pages, .mean = mean, .m2 = m2 };
}

pub fn format(buf: []u8, s: Speed) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d} {d:.3} {d:.3}\n", .{ format_tag, s.pages, s.mean, s.m2 }) catch "";
}

fn page(s: *Speed, words: u64, seconds: u64) void {
    s.record(words, seconds * 1_000_000);
}

test "speed learns from real reading only" {
    var s = Speed{};
    page(&s, 250, 1); // A flick: 15000 wpm
    page(&s, 250, 600); // Looked away: 25 wpm
    page(&s, 5, 10); // A title page
    try std.testing.expectEqual(@as(u32, 0), s.pages);
    for (0..4) |_| page(&s, 250, 60);
    try std.testing.expect(!s.known());
    try std.testing.expect(s.minutesFor(1000) == null);
    page(&s, 250, 60);
    try std.testing.expect(s.known());
    // 250 words a minute: 1000 more words is 4 minutes, 1001 rounds up to 5.
    try std.testing.expectEqual(@as(u64, 4), s.minutesFor(1000).?);
    try std.testing.expectEqual(@as(u64, 5), s.minutesFor(1001).?);
}

test "skimming and odd pages don't move the speed" {
    var s = Speed{};
    for (0..20) |i| page(&s, 250 + i % 3 * 10, 60); // 250 to 270 wpm
    const before = s.mean;
    page(&s, 700, 60); // Skimming
    page(&s, 250, 30); // 500 wpm: improbable for this reader
    try std.testing.expectEqual(before, s.mean);
    page(&s, 265, 60); // Ordinary page still counts
    try std.testing.expectEqual(@as(u32, 21), s.pages);
}

test "words are runs of non-spaces" {
    try std.testing.expectEqual(@as(u64, 0), countWords("  "));
    try std.testing.expectEqual(@as(u64, 4), countWords("Café — done, really"));
    try std.testing.expectEqual(@as(u64, 2), countWords(" two\nwords "));
}

test "durations read naturally" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12 min", formatMinutes(&buf, 12));
    try std.testing.expectEqualStrings("1 min", formatMinutes(&buf, 0));
    try std.testing.expectEqualStrings("1 h 5 min", formatMinutes(&buf, 65));
    try std.testing.expectEqualStrings("3 h", formatMinutes(&buf, 180));
}

test "speed survives a save" {
    var buf: [64]u8 = undefined;
    var s = Speed{};
    for (0..6) |i| page(&s, 240 + i, 60);
    const back = parse(format(&buf, s));
    try std.testing.expectEqual(s.pages, back.pages);
    try std.testing.expectApproxEqAbs(s.mean, back.mean, 0.001);
    try std.testing.expectEqual(Speed{}, parse("garbage"));
    try std.testing.expectEqual(Speed{}, parse("13203 57\n")); // The old byte-based file
}
