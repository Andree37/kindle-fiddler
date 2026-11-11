//! Finding a book's characters in the part already read: names are capitalised words,
//! and runs of them ("Luo Ji", "Mr. Bingley"), seen in the middle of sentences, so a
//! word that's only capitalised for starting one doesn't count. A title is part of who
//! someone is (Mr. and Miss Bingley are two people); without one, forms that share a
//! first word are one ("Elizabeth Bennet", "Elizabeth"), and a bare surname joins its
//! most mentioned titled form ("Bingley" is Mr. Bingley). The descriptions come later, from
//! the sentences each name appears in.
const std = @import("std");
const book_model = @import("book.zig");

/// A character found: the way the book usually names them, and how often they appear.
pub const Character = struct {
    name: []const u8, // Points into the book's text
    key: []const u8, // "Mr. Bingley" with a title, else the name's first word
    mentions: u32,
    first_para: u32, // Where they first appear
};

/// How often a name must appear to count as a character, not a passing mention.
pub const min_mentions = 4;

/// Capitalised words that are seldom names, even mid-sentence.
const not_names = [_][]const u8{
    "I",       "I'm",      "I'd",       "I'll",    "I've",     "Mr",      "Mrs",     "Ms",      "Miss",    "Dr",
    "Sir",     "Lady",     "Lord",      "Captain", "God",      "Chapter", "Part",    "Book",    "The",     "A",
    "An",      "And",      "But",       "Or",      "If",       "Oh",      "OK",      "Okay",    "Yes",     "No",
    "Monday",  "Tuesday",  "Wednesday", "Thursday", "Friday",  "Saturday", "Sunday", "January", "February", "March",
    "April",   "May",      "June",      "July",    "August",   "September", "October", "November", "December", "English",
    "French",  "American", "British",   "Christmas", "TV",     "Mother",  "Father",  "Mom",     "Dad",     "She",
    "He",      "It",       "We",        "They",    "You",      "My",      "His",     "Her",     "Their",   "Our",
    "Your",    "This",     "That",      "These",   "Those",    "What",    "When",    "Where",   "How",     "Why",
    "Who",     "There",    "Here",      "To",      "In",       "On",      "At",      "As",      "So",      "Then",
    "Now",     "Yet",      "Not",       "Do",      "Did",      "Well",    "Ah",      "Dear",    "Pray",    "Indeed",
};

/// Titles that stay part of a name when they come just before it.
const titles = [_][]const u8{ "Mr", "Mrs", "Ms", "Miss", "Dr", "Sir", "Lady", "Lord", "Captain", "Colonel", "Professor", "Commander", "General" };

/// Titles shortened with a full stop; a whole word's full stop ends the sentence
/// ("Yes, Commander. I'm here").
const abbreviations = [_][]const u8{ "Mr", "Mrs", "Ms", "Dr" };

fn isTitle(word: []const u8) bool {
    const w = std.mem.trimEnd(u8, word, ".");
    const dotted = w.len < word.len;
    for (titles) |t| {
        if (!std.mem.eql(u8, w, t)) continue;
        if (!dotted) return true;
        for (abbreviations) |short| {
            if (std.mem.eql(u8, t, short)) return true;
        }
        return false;
    }
    return false;
}

/// Words before a name that say it's a thing or a place, not someone: "the
/// Wallfacer", "at Netherfield".
fn isPlaceWord(word: []const u8) bool {
    for ([_][]const u8{ "the", "a", "an", "in", "on", "at", "into" }) |w| {
        if (std.ascii.eqlIgnoreCase(word, w)) return true;
    }
    return false;
}

fn isNotName(word: []const u8) bool {
    // Contractions, with either apostrophe: I'm, You're, We'll. A name's apostrophe
    // comes before a capital (O'Brien), and "'s" is trimmed before this.
    for ([_][]const u8{ "'", "\u{2019}" }) |mark| {
        if (std.mem.indexOf(u8, word, mark)) |i| {
            const after = word[i + mark.len ..];
            if (after.len > 0 and std.ascii.isLower(after[0])) return true;
        }
    }
    for (not_names) |n| {
        if (std.mem.eql(u8, word, n)) return true;
    }
    return false;
}

fn startsUpper(word: []const u8) bool {
    if (word.len == 0) return false;
    if (std.ascii.isUpper(word[0])) return true;
    // Latin-1 capitals are C3 80..9E (but not the multiplication sign)
    return word.len > 1 and word[0] == 0xc3 and word[1] >= 0x80 and word[1] <= 0x9e and word[1] != 0x97;
}

/// The word without quotes or punctuation around it, and without "'s".
fn bare(word: []const u8) []const u8 {
    var w = word;
    const lead = "\"'(\u{201c}\u{2018}";
    const trail = "\"'),.;:!?\u{201d}\u{2019}\u{2014}";
    w = std.mem.trimStart(u8, w, lead);
    w = std.mem.trimEnd(u8, w, trail);
    if (std.mem.endsWith(u8, w, "'s")) w = w[0 .. w.len - 2];
    if (std.mem.endsWith(u8, w, "\u{2019}s")) w = w[0 .. w.len - 4];
    return w;
}

fn opensQuote(word: []const u8) bool {
    return std.mem.startsWith(u8, word, "\"") or std.mem.startsWith(u8, word, "\u{201c}") or
        std.mem.startsWith(u8, word, "(") or std.mem.startsWith(u8, word, "\u{2018}");
}

/// Whether punctuation follows a word, so a name can't run on past it: "Elizabeth,"
/// ends there. A title's own full stop doesn't count ("Mr. Bingley").
fn closesRun(word: []const u8) bool {
    if (isTitle(word)) return false;
    var w = word;
    if (std.mem.endsWith(u8, w, "'s")) w = w[0 .. w.len - 2];
    if (std.mem.endsWith(u8, w, "\u{2019}s")) w = w[0 .. w.len - 4];
    if (w.len == 0) return false;
    return std.mem.indexOfScalar(u8, ",.;:!?\")'", w[w.len - 1]) != null or
        std.mem.endsWith(u8, w, "\u{201d}") or std.mem.endsWith(u8, w, "\u{2019}") or std.mem.endsWith(u8, w, "\u{2014}");
}

/// Whether a word closes a sentence, so the next capital may just start one.
fn endsSentence(word: []const u8) bool {
    const w = std.mem.trimEnd(u8, word, "\"')\u{201d}\u{2019}");
    if (w.len == 0) return false;
    if (isTitle(word)) return false; // "Mr." doesn't end a sentence
    return switch (w[w.len - 1]) {
        '.', '!', '?', ':' => true,
        else => false,
    };
}

/// The characters in `paragraphs` up to (not including) paragraph `until`, most
/// mentioned first, at most `out.len` of them. Names point into the paragraphs.
pub fn find(alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, until: usize, out: []Character) ![]Character {
    const Entry = struct { name: []const u8, mentions: u32, first_para: u32, placey: u32 = 0 };
    var by_key: std.StringArrayHashMapUnmanaged(Entry) = .empty;
    defer by_key.deinit(alloc);
    // Words seen capitalised mid-sentence: only those count at a sentence's start too
    var mid: std.StringHashMapUnmanaged(void) = .empty;
    defer mid.deinit(alloc);
    // How often each way of writing a name appears, to show the usual one
    var forms: std.StringHashMapUnmanaged(u32) = .empty;
    defer forms.deinit(alloc);

    for (0..2) |pass| {
        for (paragraphs[0..@min(until, paragraphs.len)], 0..) |p, para| {
            if (p.note or p.image != null) continue;
            var words = std.mem.tokenizeAny(u8, p.text, " \n");
            var sentence_start = true;
            var run_start: ?usize = null; // Byte where a run of capitalised words began
            var run_end: usize = 0;
            var run_from_start = false;
            var run_closed = false; // The run's last word had punctuation after it
            var last: []const u8 = ""; // The word before this one
            var run_after: []const u8 = ""; // The word before the run
            while (true) {
                const next = words.next();
                const word = next orelse "";
                const clean = bare(word);
                // A quote opening a word opens a sentence: “She said…
                if (next != null and opensQuote(word)) sentence_start = true;
                const capital = next != null and startsUpper(clean) and !isNotName(clean) or (next != null and isTitle(clean));
                const at = if (next) |w| @intFromPtr(w.ptr) - @intFromPtr(p.text.ptr) else p.text.len;
                if (capital and (run_start == null or !run_closed) and !(run_start != null and opensQuote(word))) {
                    if (run_start == null) {
                        run_start = at + (@intFromPtr(clean.ptr) - @intFromPtr(word.ptr));
                        run_from_start = sentence_start;
                        run_after = last;
                    }
                    run_end = at + (@intFromPtr(clean.ptr) - @intFromPtr(word.ptr)) + clean.len;
                    run_closed = closesRun(word);
                } else if (run_start) |rs| {
                    try takeRun(alloc, p.text[rs..run_end], run_from_start, isPlaceWord(bare(run_after)), pass, @intCast(para), &by_key, &mid, &forms);
                    run_start = null;
                    if (capital) {
                        run_start = at + (@intFromPtr(clean.ptr) - @intFromPtr(word.ptr));
                        run_end = run_start.? + clean.len;
                        run_from_start = sentence_start;
                        run_after = last;
                        run_closed = closesRun(word);
                    }
                }
                if (next == null) break;
                sentence_start = endsSentence(word);
                last = word;
            }
        }
        if (pass == 0) by_key.clearRetainingCapacity();
    }

    // A bare surname ("Bingley") joins the most mentioned titled form of it
    {
        var i: usize = 0;
        while (i < by_key.count()) {
            const key = by_key.keys()[i];
            if (std.mem.indexOfScalar(u8, key, ' ') != null) {
                i += 1;
                continue;
            }
            var best: ?usize = null;
            for (by_key.keys(), 0..) |other, j| {
                const space = std.mem.lastIndexOfScalar(u8, other, ' ') orelse continue;
                if (!std.mem.eql(u8, other[space + 1 ..], key)) continue;
                if (best == null or by_key.values()[j].mentions > by_key.values()[best.?].mentions) best = j;
            }
            if (best) |b| {
                const extra = by_key.values()[i];
                const into = &by_key.values()[b];
                into.mentions += extra.mentions;
                into.placey += extra.placey;
                into.first_para = @min(into.first_para, extra.first_para);
                // Shown the way the book names them most: "Luo Ji", not "Dr. Luo"
                if ((forms.get(extra.name) orelse 0) > (forms.get(into.name) orelse 0)) into.name = extra.name;
                by_key.swapRemoveAt(i);
                continue; // The entry now at i is unchecked
            }
            i += 1;
        }
    }

    var n: usize = 0;
    var it = by_key.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.mentions < min_mentions) continue;
        // Mostly after "the", "at" and such: a thing or a place
        if (kv.value_ptr.placey * 10 > kv.value_ptr.mentions * 4) continue;
        // "Wallfacers" beside "Wallfacer": a group of them, not one more person
        const key = kv.key_ptr.*;
        if (key.len > 2 and key[key.len - 1] == 's' and by_key.contains(key[0 .. key.len - 1])) continue;
        const c = Character{ .name = kv.value_ptr.name, .key = kv.key_ptr.*, .mentions = kv.value_ptr.mentions, .first_para = kv.value_ptr.first_para };
        if (n < out.len) {
            out[n] = c;
            n += 1;
        } else {
            // Full: replace the least mentioned if this one is mentioned more
            var least: usize = 0;
            for (out, 0..) |o, i| {
                if (o.mentions < out[least].mentions) least = i;
            }
            if (c.mentions > out[least].mentions) out[least] = c;
        }
    }
    std.mem.sort(Character, out[0..n], {}, struct {
        fn more(_: void, a: Character, b: Character) bool {
            if (a.mentions != b.mentions) return a.mentions > b.mentions;
            return a.first_para < b.first_para; // Ties: who appears first
        }
    }.more);
    return out[0..n];
}

/// One run of capitalised words: a mention of the character named by its last word.
/// The first pass only notes which names appear mid-sentence.

fn takeRun(
    alloc: std.mem.Allocator,
    run: []const u8,
    at_sentence_start: bool,
    placey: bool, // After "the", "at" and the like
    pass: usize,
    para: u32,
    by_key: anytype,
    mid: *std.StringHashMapUnmanaged(void),
    forms: *std.StringHashMapUnmanaged(u32),
) !void {
    var name = std.mem.trim(u8, run, " ");
    if (name.len == 0) return;
    // At a sentence's start the first word may be capitalised only for that ("Then
    // Ann"): drop leading words until one that's a name elsewhere. The first pass
    // can't know yet, so it skips just the first word.
    if (at_sentence_start) {
        while (name.len > 0) {
            const space = std.mem.indexOfScalar(u8, name, ' ');
            const first = bare(if (space) |sp| name[0..sp] else name);
            if (pass == 1 and (mid.contains(first) or isTitle(first))) break;
            name = if (space) |sp| std.mem.trimStart(u8, name[sp + 1 ..], " ") else "";
            if (pass == 0) break;
        }
        if (name.len == 0) return;
    }
    // Who it is: with a title, the title and the word after it ("Mr. Bingley" and
    // "Miss Bingley" are two people); without one, the first word ("Elizabeth Bennet"
    // is Elizabeth, as she's mostly called). A title alone isn't a name.
    var parts = std.mem.tokenizeScalar(u8, name, ' ');
    var key: []const u8 = "";
    var key_start: ?usize = null;
    while (parts.next()) |w| {
        const start = @intFromPtr(w.ptr) - @intFromPtr(name.ptr);
        if (isTitle(w)) {
            key_start = start; // The last title before the name
            continue;
        }
        const word = bare(w);
        const from = key_start orelse start;
        key = name[from .. start + word.len];
        break;
    }
    if (key.len < 2 or isNotName(key)) return;
    if (pass == 0) {
        try mid.put(alloc, key, {});
        return;
    }
    const gop = try by_key.getOrPut(alloc, key);
    if (!gop.found_existing) gop.value_ptr.* = .{ .name = name, .mentions = 0, .first_para = para };
    gop.value_ptr.mentions += 1;
    if (placey) gop.value_ptr.placey += 1;
    // Show the most usual way of writing the name, the fuller one on a tie
    const form = try forms.getOrPut(alloc, name);
    if (!form.found_existing) form.value_ptr.* = 0;
    form.value_ptr.* += 1;
    const shown = forms.get(gop.value_ptr.name) orelse 0;
    if (form.value_ptr.* > shown or (form.value_ptr.* == shown and name.len > gop.value_ptr.name.len)) gop.value_ptr.name = name;
}

fn paras(texts: []const []const u8) [8]book_model.Paragraph {
    var out: [8]book_model.Paragraph = undefined;
    for (texts, 0..) |t, i| out[i] = .{ .text = t, .style = 0 };
    return out;
}

test "names are found mid-sentence and merged by their first word" {
    const texts = [_][]const u8{
        "It is a truth that Mr. Bingley came to Netherfield. The house was let to Bingley at once.",
        "Everyone said that Bingley was pleasant, and Elizabeth agreed with Jane about Bingley.",
        "Then Elizabeth laughed. Elizabeth Bennet walked to Netherfield with Jane while Jane smiled.",
        "When the ball came, Mr. Bingley danced with Jane, and Elizabeth watched. But Darcy did not.",
        "Elizabeth thought Jane was happy. Jane said nothing to Elizabeth about it.",
    };
    const ps = paras(&texts);
    var out: [10]Character = undefined;
    const found = try find(std.testing.allocator, ps[0..texts.len], texts.len, &out);
    // Each shown the way the text usually writes them
    var saw_elizabeth = false;
    var saw_bingley = false;
    var saw_jane = false;
    for (found) |c| {
        if (std.mem.eql(u8, c.key, "Mr. Bingley")) saw_bingley = true;
        if (std.mem.eql(u8, c.name, "Elizabeth")) saw_elizabeth = true; // Her usual form
        if (std.mem.eql(u8, c.key, "Jane")) saw_jane = true;
        try std.testing.expect(!std.mem.eql(u8, c.key, "Bingley")); // Joined Mr. Bingley
        try std.testing.expect(!std.mem.eql(u8, c.key, "The"));
        try std.testing.expect(!std.mem.eql(u8, c.key, "When"));
        try std.testing.expect(!std.mem.eql(u8, c.key, "Darcy")); // Only once
    }
    try std.testing.expect(saw_bingley and saw_jane and saw_elizabeth);
}

test "only the part already read counts" {
    const texts = [_][]const u8{
        "Then Ann met Ann's friend and Ann laughed with Ann.",
        "Later Zed came, and Zed and Zed and Zed talked with Ann.",
    };
    const ps = paras(&texts);
    var out: [10]Character = undefined;
    const found = try find(std.testing.allocator, ps[0..texts.len], 1, &out);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Ann", found[0].key);
}

test "places, groups and lines of dialogue aren't characters" {
    const texts = [_][]const u8{
        "They rode to Netherfield, and at Netherfield the Wallfacer waited. Luo Ji smiled.",
        "In Netherfield, Luo Ji spoke to the Wallfacer. The Wallfacers met at Netherfield.",
        "“Yes, Commander. I’m ready,” said Luo Ji. Dr. Luo laughed, and the Wallfacers left.",
        "Later Luo Ji met Dr. Luo's friend, and the Wallfacer and the Wallfacers left Netherfield.",
    };
    const ps = paras(&texts);
    var out: [10]Character = undefined;
    const found = try find(std.testing.allocator, ps[0..texts.len], texts.len, &out);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Luo Ji", found[0].name); // His usual name, not "Dr. Luo"
}

test "contractions aren't names, apostrophes in names are" {
    try std.testing.expect(isNotName("I’m"));
    try std.testing.expect(isNotName("You’re"));
    try std.testing.expect(isNotName("We'll"));
    try std.testing.expect(!isNotName("O'Brien"));
    try std.testing.expect(!isNotName("Elizabeth"));
}
