//! What helps a reader back into a book: the sentences a character was last seen in,
//! who's been around lately, and the words just before where they stopped. All of it
//! from the part already read, so nothing ahead is given away.
const std = @import("std");
const book_model = @import("book.zig");
const characters = @import("characters.zig");

/// A stretch of one paragraph's text: a sentence, or the tail of a passage.
pub const Span = struct { para: u32, start: u32, end: u32 };

pub fn text(paragraphs: []const book_model.Paragraph, s: Span) []const u8 {
    return paragraphs[s.para].text[s.start..s.end];
}

/// Away this long, a book opens with a recap.
pub const recap_after_s = 3 * 24 * 60 * 60;

pub fn wantsRecap(last_opened: u64, now: u64) bool {
    return last_opened != 0 and now > last_opened and now - last_opened >= recap_after_s;
}

fn isLetter(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Where `name` appears in `t` as a whole word, from `from` on.
fn findWord(t: []const u8, name: []const u8, from: usize) ?usize {
    var at = from;
    while (std.mem.indexOfPos(u8, t, at, name)) |i| {
        const before_ok = i == 0 or !isLetter(t[i - 1]);
        const after = i + name.len;
        // "Jane's" counts; "Janet" doesn't
        const after_ok = after >= t.len or !isLetter(t[after]) or t[after] == '\'' or
            (after + 1 < t.len and t[after] == 0xe2);
        if (before_ok and after_ok) return i;
        at = i + 1;
    }
    return null;
}

fn endsSentenceAt(t: []const u8, i: usize) bool {
    return switch (t[i]) {
        '.', '!', '?' => i + 1 >= t.len or t[i + 1] == ' ' or t[i + 1] == '"' or t[i + 1] == 0xe2,
        else => false,
    };
}

/// The titles whose full stop doesn't end a sentence.
fn afterTitle(t: []const u8, dot: usize) bool {
    for ([_][]const u8{ "Mr", "Mrs", "Ms", "Dr", "St" }) |title| {
        if (dot >= title.len and std.mem.eql(u8, t[dot - title.len .. dot], title) and
            (dot == title.len or t[dot - title.len - 1] == ' ')) return true;
    }
    return false;
}

/// The sentence around byte `at` of paragraph `para`, at most `max` bytes, trimmed
/// at word edges if longer, centred on `at`.
pub fn sentenceAround(paragraphs: []const book_model.Paragraph, para: u32, at: usize, max: usize) Span {
    const t = paragraphs[para].text;
    var start = at;
    while (start > 0) : (start -= 1) {
        const i = start - 1;
        if (endsSentenceAt(t, i) and !afterTitle(t, i)) break;
    }
    var end = at;
    while (end < t.len) : (end += 1) {
        if (endsSentenceAt(t, end) and !afterTitle(t, end)) {
            end += 1;
            // Keep a closing quote with its sentence
            while (end < t.len and t[end] != ' ') end += 1;
            break;
        }
    }
    while (start < t.len and t[start] == ' ') start += 1;
    if (end - start > max) {
        const half = max / 2;
        if (at > start + half) start = wordStart(t, at - half);
        if (end > start + max) end = wordEnd(t, start + max);
    }
    return .{ .para = para, .start = @intCast(start), .end = @intCast(end) };
}

fn wordStart(t: []const u8, i: usize) usize {
    var j = i;
    while (j < t.len and t[j] != ' ') j += 1;
    return @min(j + 1, t.len);
}

fn wordEnd(t: []const u8, i: usize) usize {
    var j = @min(i, t.len);
    while (j > 0 and t[j - 1] != ' ') j -= 1;
    return if (j > 0) j - 1 else i;
}

/// The last sentences a character appears in before paragraph `until`, oldest first,
/// at most `out.len` of them, one per paragraph.
pub fn lastSeen(paragraphs: []const book_model.Paragraph, c: characters.Character, until: usize, out: []Span) []Span {
    var n: usize = 0;
    var para = @min(until, paragraphs.len);
    while (para > c.first_para and n < out.len) {
        para -= 1;
        const p = paragraphs[para];
        if (p.note or p.image != null) continue;
        // The usual form first, then how they're known ("Bingley" for Mr. Bingley)
        const at = findWord(p.text, c.name, 0) orelse findWord(p.text, c.key, 0) orelse
            findWord(p.text, lastWord(c.key), 0) orelse continue;
        out[n] = sentenceAround(paragraphs, @intCast(para), at, 360);
        n += 1;
    }
    std.mem.reverse(Span, out[0..n]);
    return out[0..n];
}

fn lastWord(name: []const u8) []const u8 {
    const space = std.mem.lastIndexOfScalar(u8, name, ' ') orelse return name;
    return name[space + 1 ..];
}

fn countIn(t: []const u8, name: []const u8) u32 {
    var n: u32 = 0;
    var at: usize = 0;
    while (findWord(t, name, at)) |i| {
        n += 1;
        at = i + name.len;
    }
    return n;
}

/// Of `cast`, who appears most in the `window` paragraphs before `until`, most first.
/// Fills `out` with indexes into `cast`.
pub fn lately(paragraphs: []const book_model.Paragraph, cast: []const characters.Character, until: usize, window: usize, out: []usize) []usize {
    var counts: [64]u32 = @splat(0);
    const end = @min(until, paragraphs.len);
    const shown = @min(cast.len, counts.len);
    for (paragraphs[end -| window .. end]) |p| {
        if (p.note or p.image != null) continue;
        for (cast[0..shown], 0..) |c, i| counts[i] += countIn(p.text, lastWord(c.key));
    }
    var n: usize = 0;
    while (n < out.len) {
        var best: ?usize = null;
        for (counts[0..shown], 0..) |count, i| {
            if (count > 0 and (best == null or count > counts[best.?])) best = i;
        }
        const b = best orelse break;
        out[n] = b;
        counts[b] = 0;
        n += 1;
    }
    return out[0..n];
}

/// The text just before `pos`, about `max` bytes of it, starting at a sentence, as
/// spans of the paragraphs it covers (oldest first). Fills `out` from its end.
pub fn before(paragraphs: []const book_model.Paragraph, pos: book_model.Pos, max: usize, out: []Span) []Span {
    var n: usize = 0;
    var left = max;
    // First the part of `pos`'s own paragraph before it, then whole ones going back
    var para: usize = @min(pos.para, paragraphs.len);
    var stop: usize = if (para < paragraphs.len) @min(pos.byte, paragraphs[para].text.len) else 0;
    while (left > 0 and n < out.len) {
        if (stop == 0) {
            if (para == 0) break;
            para -= 1;
            const p = paragraphs[para];
            if (p.note or p.image != null) continue;
            stop = p.text.len;
            continue;
        }
        const t = paragraphs[para].text;
        var start: usize = 0;
        if (stop > left) {
            // Too long: from the first sentence that fits, else a word
            var i = stop - left;
            while (i < stop and !(endsSentenceAt(t, i - 1) and !afterTitle(t, i - 1))) i += 1;
            start = if (i < stop) i else wordStart(t, stop - left);
            while (start < stop and t[start] == ' ') start += 1;
            if (start >= stop) break;
        }
        out[out.len - 1 - n] = .{ .para = @intCast(para), .start = @intCast(start), .end = @intCast(stop) };
        n += 1;
        left -|= stop - start;
        if (start > 0) break;
        stop = 0;
    }
    return out[out.len - n ..];
}

fn paras(texts: []const []const u8) [8]book_model.Paragraph {
    var out: [8]book_model.Paragraph = undefined;
    for (texts, 0..) |t, i| out[i] = .{ .text = t, .style = 0 };
    return out;
}

test "a recap comes after three days away" {
    try std.testing.expect(!wantsRecap(0, 1_000_000));
    try std.testing.expect(!wantsRecap(1_000_000, 1_000_000 + 2 * 86400));
    try std.testing.expect(wantsRecap(1_000_000, 1_000_000 + 3 * 86400));
    try std.testing.expect(!wantsRecap(1_000_000, 900_000)); // Clock set back
}

test "the sentence a name is in, not stopped by Mr." {
    const texts = [_][]const u8{"It rained. Then Mr. Bingley came to tea! Nobody minded."};
    const ps = paras(&texts);
    const at = std.mem.indexOf(u8, texts[0], "Bingley").?;
    const s = sentenceAround(&ps, 0, at, 400);
    try std.testing.expectEqualStrings("Then Mr. Bingley came to tea!", text(&ps, s));
    const short = sentenceAround(&ps, 0, at, 12);
    try std.testing.expect(short.end - short.start <= 14);
}

test "last seen: the latest sentences, oldest first, only before the place" {
    const texts = [_][]const u8{
        "Jane walked in. It was cold.",
        "Nothing here.",
        "Later, Jane's sister laughed.",
        "Janet came by. Then Jane left.",
        "Jane returned, far ahead.",
    };
    const ps = paras(&texts);
    const jane = characters.Character{ .name = "Jane", .key = "Jane", .mentions = 4, .first_para = 0 };
    var out: [2]Span = undefined;
    const seen = lastSeen(&ps, jane, 4, &out);
    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expectEqualStrings("Later, Jane's sister laughed.", text(&ps, seen[0]));
    try std.testing.expectEqualStrings("Then Jane left.", text(&ps, seen[1]));
}

test "who's been around lately" {
    const texts = [_][]const u8{
        "Ann and Ann and Ann.",
        "Bob met Cat. Bob smiled.",
        "Cat and Bob.",
    };
    const ps = paras(&texts);
    const cast = [_]characters.Character{
        .{ .name = "Ann", .key = "Ann", .mentions = 3, .first_para = 0 },
        .{ .name = "Cat", .key = "Cat", .mentions = 2, .first_para = 1 },
        .{ .name = "Mr. Bob", .key = "Mr. Bob", .mentions = 3, .first_para = 1 },
    };
    var out: [3]usize = undefined;
    const who = lately(&ps, &cast, 3, 2, &out);
    try std.testing.expectEqual(@as(usize, 2), who.len);
    try std.testing.expectEqual(@as(usize, 2), who[0]); // Bob, as "Bob"
    try std.testing.expectEqual(@as(usize, 1), who[1]);
}

test "the words before the place, from a sentence's start" {
    const texts = [_][]const u8{
        "First one. Second one is here.",
        "Third paragraph runs on. And on.",
    };
    const ps = paras(&texts);
    var out: [4]Span = undefined;
    // Stopped part way into the second paragraph, after "Third paragraph runs on. "
    const got = before(&ps, .{ .para = 1, .byte = 25 }, 50, &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("Second one is here.", text(&ps, got[0]));
    try std.testing.expectEqualStrings("Third paragraph runs on. ", text(&ps, got[1]));
    // At a paragraph's start: only what came before
    const at_start = before(&ps, .{ .para = 1, .byte = 0 }, 400, &out);
    try std.testing.expectEqual(@as(usize, 1), at_start.len);
    try std.testing.expectEqualStrings("First one. Second one is here.", text(&ps, at_start[0]));
}
