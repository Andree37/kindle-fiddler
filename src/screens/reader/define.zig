//! Holding a word without dragging: its definition, in a sheet over the page.
const std = @import("std");
const definition = @import("../../ui/definition.zig");
const dictionary = @import("../../model/dictionary.zig");
const book_model = @import("../../model/book.zig");
const hyphen = @import("../../layout/hyphen.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const dict_get = @import("dict_get.zig");

pub const Choice = enum { close, highlight };

/// What the dictionary has for a word of the book.
pub fn find(a: *app.App, s: *const sess.Session, word: book_model.Word, lang: ?hyphen.Lang) definition.Found {
    const text = dictionary.trimmed(s.paragraphs[word.para].text[word.start..word.end]);
    var found = definition.Found{ .word = text };
    const d = a.dictionaryFor(lang) orelse {
        found.no_dictionary = true;
        return found;
    };
    found.entry = d.lookup(text);
    if (found.entry) |e| {
        if (e.baseForm()) |b| found.base = d.lookup(b);
    }
    return found;
}

/// Shows the sheet until it's closed or Highlight is pressed. What was on screen
/// is put back either way.
pub fn run(a: *app.App, s: *const sess.Session, word: book_model.Word, lang: ?hyphen.Lang) !Choice {
    var found = find(a, s, word, lang);
    std.debug.print("lookup: found {}, form of another {}\n", .{ found.entry != null, found.base != null });
    @memcpy(a.overlay, a.screen.pixels);
    // The page as it was, for the cards about getting a dictionary to sit over
    const page_copy = try a.alloc.dupe(u8, a.screen.pixels);
    defer a.alloc.free(page_copy);
    if (found.no_dictionary) if (lang) |l| {
        found.can_get = dict_get.languageOf(l).name;
        // The first time, ask; after "Not now", the sheet offers it instead
        if (a.settings.offer_dictionary and try dict_get.ask(a, page_copy, l) == .download) {
            if (try dict_get.get(a, page_copy, l)) found = find(a, s, word, lang);
        }
    };
    try definition.render(a.ui, a.page(a.screen.pixels), found);
    try a.showBand(0, a.screen.height);
    // Highlight sits along the bottom, where a resting thumb is otherwise ignored
    a.input.grips = false;
    defer a.input.grips = true;
    const choice: Choice = while (true) {
        const action = a.input.next();
        switch (action) {
            .tap => |t| switch (definition.hit(t.x, t.y)) {
                .close => break .close,
                .highlight => break .highlight,
                .get_dictionary => if (found.no_dictionary) if (lang) |l| {
                    if (try dict_get.get(a, page_copy, l)) found = find(a, s, word, lang);
                    @memcpy(a.screen.pixels, page_copy);
                    if (found.no_dictionary) found.can_get = dict_get.languageOf(l).name;
                    try definition.render(a.ui, a.page(a.screen.pixels), found);
                    try a.showBand(0, a.screen.height);
                },
                .none => {},
            },
            .lock, .power, .computer, .stop => {
                a.input.stashed = action;
                break .close;
            },
            else => {},
        }
    };
    @memcpy(a.screen.pixels, a.overlay);
    try a.showBand(0, a.screen.height);
    return choice;
}
