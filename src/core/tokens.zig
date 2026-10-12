//! Tokenizer shared by the derived layer (spec/derived.md sections 3, 4, 7).
//!
//! A token is a maximal run of ASCII letters in the source text. Tokens are
//! lowercased to their canonical form before use; the stopword lists are
//! frozen consts (spec/derived.md section 4) pinned by test vectors and
//! version-gated by the index version byte.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One token's span in the source text: [start, end).
pub const Span = struct {
    start: usize,
    end: usize,
};

/// Maximal runs of ASCII letters in `text`, in order of appearance.
/// Runs of every length are returned; the length filter is the caller's,
/// because entity extraction treats short capitalized words differently.
pub fn spans(allocator: Allocator, text: []const u8) Allocator.Error![]const Span {
    var list = std.ArrayList(Span).empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isAlphabetic(text[i])) continue;
        const start = i;
        while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
        try list.append(allocator, .{ .start = start, .end = i });
    }
    return list.toOwnedSlice(allocator);
}

/// The token's text within `text` (borrowed, not lowercased).
pub fn token(text: []const u8, s: Span) []const u8 {
    return text[s.start..s.end];
}

/// Case-insensitive membership in `stoplist`.
pub fn isStopword(text: []const u8, s: Span, stoplist: []const []const u8) bool {
    const t = token(text, s);
    for (stoplist) |w| {
        if (std.ascii.eqlIgnoreCase(t, w)) return true;
    }
    return false;
}

/// The lowercased token (tokens are ASCII, so a byte-wise fold).
pub fn lowercase(allocator: Allocator, text: []const u8, s: Span) Allocator.Error![]u8 {
    const t = token(text, s);
    const out = try allocator.alloc(u8, t.len);
    errdefer allocator.free(out);
    for (out, t) |*o, c| o.* = std.ascii.toLower(c);
    return out;
}

/// Question stopwords for `ask` keyword retrieval. A question whose tokens
/// are all stopwords retrieves nothing: the pack carries period context only.
pub const QuestionStopwords = [_][]const u8{
    "about",    "after",  "again",   "all",     "along",   "also",   "always", "among",   "another", "any",    "anyone",
    "anything", "are",    "around",  "because", "been",    "before", "being",  "below",   "between", "both",   "but",
    "by",       "can",    "cannot",  "could",   "did",     "does",   "doing",  "done",    "down",    "during", "each",
    "else",     "few",    "for",     "from",    "further", "get",    "got",    "had",     "has",     "have",   "having",
    "he",       "her",    "here",    "hers",    "him",     "his",    "how",    "however", "if",      "in",     "into",
    "is",       "it",     "its",     "just",    "may",     "me",     "might",  "more",    "most",    "much",   "must",
    "my",       "near",   "no",      "nor",     "not",     "now",    "of",     "off",     "on",      "once",   "one",
    "only",     "onto",   "or",      "other",   "our",     "ours",   "out",    "over",    "own",     "said",   "same",
    "saw",      "say",    "says",    "she",     "should",  "since",  "so",     "some",    "still",   "such",   "than",
    "that",     "the",    "their",   "theirs",  "them",    "then",   "there",  "these",   "they",    "this",   "those",
    "through",  "to",     "too",     "under",   "until",   "up",     "upon",   "very",    "was",     "we",     "were",
    "what",     "when",   "where",   "which",   "while",   "who",    "whole",  "whom",    "whose",   "why",    "will",
    "with",     "within", "without", "would",   "you",     "your",   "yours",
};

/// Entity stopwords (spec/derived.md section 4): weekday and month names,
/// which can begin a capitalized word mid-sentence ("arrived on Monday").
/// Compared case-sensitively against already-qualifying (initial-capital) words.
pub const EntityStopwords = [_][]const u8{
    "Monday",  "Tuesday",   "Wednesday", "Thursday", "Friday",   "Saturday", "Sunday",
    "January", "February",  "March",     "April",    "May",      "June",     "July",
    "August",  "September", "October",   "November", "December",
};

test "spans: letter runs, punctuation, non-ascii are delimiters" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const s = try spans(allocator, "bought milk! The Zephyr thing, café 42");
    defer allocator.free(s);
    try std.testing.expectEqual(@as(usize, 6), s.len);
    try std.testing.expectEqualStrings("bought", token("bought milk! The Zephyr thing, café 42", s[0]));
    try std.testing.expectEqualStrings("milk", token("bought milk! The Zephyr thing, café 42", s[1]));
    try std.testing.expectEqualStrings("The", token("bought milk! The Zephyr thing, café 42", s[2]));
    try std.testing.expectEqualStrings("Zephyr", token("bought milk! The Zephyr thing, café 42", s[3]));
    try std.testing.expectEqualStrings("thing", token("bought milk! The Zephyr thing, café 42", s[4]));
    try std.testing.expectEqualStrings("caf", token("bought milk! The Zephyr thing, café 42", s[5]));
    // é is not an ASCII letter: "café" tokenizes as "caf".

    const none = try spans(allocator, "123 !!  42");
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "lowercase and isStopword" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = "The ZEPHYR of zephyr";
    const s = try spans(allocator, text);
    defer allocator.free(s);

    const l0 = try lowercase(allocator, text, s[0]);
    defer allocator.free(l0);
    try std.testing.expectEqualStrings("the", l0);
    const l1 = try lowercase(allocator, text, s[1]);
    defer allocator.free(l1);
    try std.testing.expectEqualStrings("zephyr", l1);

    try std.testing.expect(isStopword(text, s[0], &QuestionStopwords)); // "The"
    try std.testing.expect(!isStopword(text, s[1], &QuestionStopwords)); // "ZEPHYR"
    try std.testing.expect(!isStopword(text, s[1], &EntityStopwords));
    const mon = try spans(allocator, "saw it on Monday");
    defer allocator.free(mon);
    try std.testing.expect(isStopword("saw it on Monday", mon[3], &EntityStopwords));
}
