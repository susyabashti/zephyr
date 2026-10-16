//! Pure derived computations of the derived layer (spec/derived.md
//! sections 3-6): the token index with its entity index, period digests,
//! and the derived profile.
//!
//! Every output here is a pure function of (verified visible entries,
//! parameters) — no clocks, no randomness — so two builds from the same
//! input are byte-identical. Disk storage, staleness, and the context pack
//! live in dstore.zig.

const std = @import("std");
const records = @import("records.zig");
const tokens = @import("tokens.zig");
const view = @import("view.zig");

const Allocator = std.mem.Allocator;

/// Lowercase hex of a hash (the CLI has its own copy; core cannot import it).
pub fn hexLower(allocator: Allocator, hash: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, hash.len * 2);
    errdefer allocator.free(out);
    for (hash, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out;
}

// ---------------------------------------------------------------- index

pub const IndexVersion: u8 = 1;
pub const Magic: [4]u8 = .{ 'Z', 'D', 'I', '1' };

/// A name (word or entity) longer than this is not indexed: the format's
/// length field is one byte. The index version byte covers a future
/// expansion (spec/derived.md section 3).
pub const MaxNameLen: usize = 255;

pub const EntityKind = enum(u8) {
    tag = 0,
    phrase = 1,
};

pub const Word = struct {
    word: []const u8,
    /// Seqs of the visible entries containing the word, ascending.
    seqs: []const u32,
};

pub const Entity = struct {
    name: []const u8,
    /// tag if any visible entry carries the name as a tag, else phrase.
    kind: EntityKind,
    first_seq: u32,
    last_seq: u32,
    /// Number of visible entries containing the entity (as tag or phrase).
    count: u32,
};

pub const Index = struct {
    head: [records.DigestLen]u8,
    record_count: u64,
    words: []Word, // sorted by word bytes
    entities: []Entity, // sorted by name bytes (names are unique)
    allocator: Allocator,

    pub fn deinit(self: Index) void {
        const allocator = self.allocator;
        freeWords(allocator, self.words);
        allocator.free(self.words);
        for (self.entities) |e| allocator.free(e.name);
        allocator.free(self.entities);
    }

    /// Binary search: the seqs for `word`, or null when absent.
    pub fn lookupWord(self: *const Index, word: []const u8) ?[]const u32 {
        var lo: usize = 0;
        var hi: usize = self.words.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.words[mid].word, word) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.words.len and std.mem.eql(u8, self.words[lo].word, word)) {
            return self.words[lo].seqs;
        }
        return null;
    }
};

fn freeWords(allocator: Allocator, words: []Word) void {
    for (words) |w| {
        allocator.free(w.word);
        allocator.free(w.seqs);
    }
}

pub const BuildIndexError = Allocator.Error || error{SeqOverflow};

/// Builds the index from the viewable entries (spec/derived.md section 3):
/// words are the shared tokenizer over each entry's text and tags (each
/// entry contributes each word once); entities are tags plus capitalized
/// phrase runs (section 4). Redacted entries carry the placeholder payload,
/// so they contribute nothing. `visible` must be a verified journal's.
pub fn buildIndex(
    allocator: Allocator,
    visible: *const view.Visible,
    head: [records.DigestLen]u8,
    record_count: u64,
) BuildIndexError!Index {
    if (record_count > std.math.maxInt(u32)) return error.SeqOverflow;

    var word_pairs = std.ArrayList(WordPair).empty;
    errdefer {
        for (word_pairs.items) |p| allocator.free(p.word);
        allocator.free(word_pairs.items);
    }
    var ent_pairs = std.ArrayList(EntPair).empty;
    errdefer allocator.free(ent_pairs.items); // names borrow from the payloads

    for (visible.entries) |e| {
        const seq: u32 = @intCast(e.seq);
        // Entry-local tokens (text + tags), lowercased, deduplicated. The
        // pair strings are duped: the entry-local copies are freed below.
        var tok = std.ArrayList([]const u8).empty;
        errdefer {
            for (tok.items) |t| allocator.free(t);
            allocator.free(tok.items);
        }
        for (e.tags) |tag| {
            if (tag.len >= 2 and tag.len <= MaxNameLen) try addToken(allocator, &tok, tag);
        }
        const sp = try tokens.spans(allocator, e.text);
        defer allocator.free(sp);
        for (sp) |s| {
            if (s.end - s.start < 2) continue;
            try addToken(allocator, &tok, tokens.token(e.text, s));
        }
        std.mem.sort([]const u8, tok.items, {}, tokenLessThan);
        var k: usize = 0;
        while (k < tok.items.len) {
            if (k > 0 and std.mem.eql(u8, tok.items[k - 1], tok.items[k])) {
                k += 1;
                continue;
            }
            const owned = try allocator.dupe(u8, tok.items[k]);
            errdefer allocator.free(owned);
            try word_pairs.append(allocator, .{ .word = owned, .seq = seq });
            k += 1;
        }

        // Entities: tags, then capitalized phrase runs. Both borrow from
        // the payloads, which outlive this build.
        for (e.tags) |tag| {
            if (tag.len <= MaxNameLen) {
                try ent_pairs.append(allocator, .{ .name = tag, .kind = .tag, .seq = seq });
            }
        }
        const runs = try phraseRuns(allocator, e.text, sp);
        defer allocator.free(runs);
        for (runs) |run| {
            if (run.len <= MaxNameLen) {
                try ent_pairs.append(allocator, .{ .name = run, .kind = .phrase, .seq = seq });
            }
        }
    }

    std.mem.sort(WordPair, word_pairs.items, {}, wordPairLessThan);
    std.mem.sort(EntPair, ent_pairs.items, {}, entPairLessThan);

    // Group (word, seq) pairs: sorted by (word, seq), so seqs per word are
    // ascending with duplicates adjacent.
    var words = std.ArrayList(Word).empty;
    errdefer {
        freeWords(allocator, words.items);
        allocator.free(words.items);
    }
    var i: usize = 0;
    while (i < word_pairs.items.len) {
        const word = word_pairs.items[i].word;
        var seqs = std.ArrayList(u32).empty;
        errdefer seqs.deinit(allocator);
        var j = i;
        while (j < word_pairs.items.len and std.mem.eql(u8, word_pairs.items[j].word, word)) {
            const s = word_pairs.items[j].seq;
            if (seqs.items.len == 0 or seqs.items[seqs.items.len - 1] != s) {
                try seqs.append(allocator, s);
            }
            j += 1;
        }
        const owned_word = try allocator.dupe(u8, word);
        errdefer allocator.free(owned_word);
        const owned_seqs = try seqs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_seqs);
        try words.append(allocator, .{ .word = owned_word, .seqs = owned_seqs });
        i = j;
    }

    // Group entity pairs the same way; identity is the name (a name that is
    // both a tag and a phrase keeps kind .tag; count spans both sources).
    var entities = std.ArrayList(Entity).empty;
    errdefer {
        for (entities.items) |e| allocator.free(e.name);
        allocator.free(entities.items);
    }
    i = 0;
    while (i < ent_pairs.items.len) {
        const name = ent_pairs.items[i].name;
        var count: u32 = 0;
        var first: u32 = 0;
        var last: u32 = 0;
        var is_tag = false;
        var j = i;
        while (j < ent_pairs.items.len and std.mem.eql(u8, ent_pairs.items[j].name, name)) {
            const p = ent_pairs.items[j];
            if (count > 0 and last == p.seq) {
                // Same entry already counted for this name.
            } else {
                if (count == 0) first = p.seq;
                last = p.seq;
                count += 1;
            }
            is_tag = is_tag or (p.kind == .tag);
            j += 1;
        }
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try entities.append(allocator, .{
            .name = owned_name,
            .kind = if (is_tag) .tag else .phrase,
            .first_seq = first,
            .last_seq = last,
            .count = count,
        });
        i = j;
    }

    const owned_words = try words.toOwnedSlice(allocator);
    const owned_entities = try entities.toOwnedSlice(allocator);
    // Success cleanup: errdefers run on error paths only, so everything is
    // released here, and no fallible call follows.
    for (word_pairs.items) |p| allocator.free(p.word);
    allocator.free(word_pairs.items);
    allocator.free(ent_pairs.items);
    freeWords(allocator, words.items);
    allocator.free(words.items);
    for (entities.items) |e| allocator.free(e.name);
    allocator.free(entities.items);
    return Index{
        .head = head,
        .record_count = record_count,
        .words = owned_words,
        .entities = owned_entities,
        .allocator = allocator,
    };
}

const WordPair = struct { word: []const u8, seq: u32 };
const EntPair = struct { name: []const u8, kind: EntityKind, seq: u32 };

fn tokenLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn wordPairLessThan(_: void, a: WordPair, b: WordPair) bool {
    const o = std.mem.order(u8, a.word, b.word);
    if (o != .eq) return o == .lt;
    return a.seq < b.seq;
}

fn entPairLessThan(_: void, a: EntPair, b: EntPair) bool {
    const o = std.mem.order(u8, a.name, b.name);
    if (o != .eq) return o == .lt;
    return a.seq < b.seq;
}

/// Lowercases `s` and appends an owned copy to `tok`.
fn addToken(allocator: Allocator, tok: *std.ArrayList([]const u8), s: []const u8) Allocator.Error!void {
    const out = try allocator.alloc(u8, s.len);
    errdefer allocator.free(out);
    for (out, s) |*o, c| o.* = std.ascii.toLower(c);
    try tok.append(allocator, out);
}

/// The entity phrase runs in `text` (spec/derived.md section 4): maximal
/// sequences of 1-4 qualifying words separated by spaces. A word qualifies
/// when it is at least 2 letters, begins with an ASCII uppercase, contains
/// a lowercase letter, is not a stopword, and does not begin a sentence.
/// Sequences longer than 4 words are ignored. Runs are returned per
/// occurrence; the caller deduplicates. The runs borrow from `text`; the
/// returned slice owns only its headers.
pub fn phraseRuns(allocator: Allocator, text: []const u8, sp: []const tokens.Span) Allocator.Error![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < sp.len) {
        if (!wordQualifies(text, sp[i])) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < sp.len and wordQualifies(text, sp[j]) and consecutive(text, sp[j - 1], sp[j])) {
            j += 1;
        }
        if (j - i <= 4) {
            try list.append(allocator, text[sp[i].start..sp[j - 1].end]);
        }
        i = j;
    }
    return list.toOwnedSlice(allocator);
}

fn wordQualifies(text: []const u8, s: tokens.Span) bool {
    const w = text[s.start..s.end];
    if (w.len < 2) return false;
    if (!std.ascii.isUpper(w[0]) or !hasLower(w)) return false;
    if (sentenceStart(text, s.start)) return false;
    return !entityStopword(w);
}

fn hasLower(w: []const u8) bool {
    for (w) |c| {
        if (std.ascii.isLower(c)) return true;
    }
    return false;
}

/// Sentence start: the text position, or a `.`, `!`, `?` with only
/// whitespace before it (spec/derived.md section 4).
fn sentenceStart(text: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    var j: usize = pos;
    while (j > 0 and std.ascii.isWhitespace(text[j - 1])) j -= 1;
    if (j == 0) return true;
    return text[j - 1] == '.' or text[j - 1] == '!' or text[j - 1] == '?';
}

/// Consecutive: only spaces (at least one) between the two words.
fn consecutive(text: []const u8, a: tokens.Span, b: tokens.Span) bool {
    const between = text[a.end..b.start];
    if (between.len == 0) return false;
    for (between) |c| {
        if (c != ' ') return false;
    }
    return true;
}

fn entityStopword(w: []const u8) bool {
    for (tokens.EntityStopwords) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}

/// Encodes the index to the ZDI1 wire form (spec/derived.md section 3),
/// including the trailing SHA-256 footer.
pub fn encodeIndex(allocator: Allocator, idx: *const Index) Allocator.Error![]u8 {
    var b = std.ArrayList(u8).empty;
    errdefer b.deinit(allocator);
    try b.appendSlice(allocator, &Magic);
    try b.append(allocator, IndexVersion);
    try b.append(allocator, 0); // flags
    try b.appendSlice(allocator, &idx.head);
    try appendU64be(allocator, &b, idx.record_count);
    try appendU64be(allocator, &b, idx.words.len);
    for (idx.words) |w| {
        try b.append(allocator, @intCast(w.word.len));
        try b.appendSlice(allocator, w.word);
        try appendU32be(allocator, &b, @intCast(w.seqs.len));
        for (w.seqs) |seq| try appendU32be(allocator, &b, seq);
    }
    try appendU64be(allocator, &b, idx.entities.len);
    for (idx.entities) |e| {
        try b.append(allocator, @intCast(e.name.len));
        try b.appendSlice(allocator, e.name);
        try b.append(allocator, @backingInt(e.kind));
        try appendU32be(allocator, &b, e.first_seq);
        try appendU32be(allocator, &b, e.last_seq);
        try appendU32be(allocator, &b, e.count);
    }
    var hasher = records.Sha256.init(.{});
    hasher.update(b.items);
    const digest = hasher.finalResult();
    try b.appendSlice(allocator, &digest);
    return b.toOwnedSlice(allocator);
}

/// Decodes ZDI1, validating magic, version, bounds, and the footer. The
/// result owns all its memory; the input bytes may be freed.
pub const DecodeIndexError = Allocator.Error || error{
    BadMagic,
    BadVersion,
    Truncated,
    BadFooter,
};

pub fn decodeIndex(allocator: Allocator, bytes: []const u8) DecodeIndexError!Index {
    const header_len = 4 + 1 + 1 + records.DigestLen + 8 + 8;
    if (bytes.len < header_len + records.DigestLen) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &Magic)) return error.BadMagic;
    if (bytes[4] != IndexVersion) return error.BadVersion;
    if (bytes[5] != 0) return error.BadVersion;
    var head: [records.DigestLen]u8 = undefined;
    @memcpy(&head, bytes[6 .. 6 + records.DigestLen]);
    const record_count = readU64be(bytes[6 + records.DigestLen .. 14 + records.DigestLen]) orelse return error.Truncated;
    const word_count = readU64be(bytes[14 + records.DigestLen .. 22 + records.DigestLen]) orelse return error.Truncated;

    var pos = header_len;
    var words = std.ArrayList(Word).empty;
    errdefer {
        freeWords(allocator, words.items);
        allocator.free(words.items);
    }
    var i: usize = 0;
    while (i < word_count) : (i += 1) {
        if (pos >= bytes.len) return error.Truncated;
        const len = bytes[pos];
        pos += 1;
        if (pos + len > bytes.len) return error.Truncated;
        const word = try allocator.dupe(u8, bytes[pos .. pos + len]);
        errdefer allocator.free(word);
        pos += len;
        const seq_count = readU32be(bytes[pos .. pos + 4]) orelse return error.Truncated;
        pos += 4;
        if (pos + 4 * seq_count > bytes.len) return error.Truncated;
        var seqs = std.ArrayList(u32).empty;
        errdefer seqs.deinit(allocator);
        var k: usize = 0;
        while (k < seq_count) : (k += 1) {
            const seq = readU32be(bytes[pos .. pos + 4]).?;
            pos += 4;
            try seqs.append(allocator, seq);
        }
        const owned_seqs = try seqs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_seqs);
        try words.append(allocator, .{ .word = word, .seqs = owned_seqs });
    }
    const entity_count = readU64be(bytes[pos .. pos + 8]) orelse return error.Truncated;
    pos += 8;
    var entities = std.ArrayList(Entity).empty;
    errdefer {
        for (entities.items) |e| allocator.free(e.name);
        allocator.free(entities.items);
    }
    i = 0;
    while (i < entity_count) : (i += 1) {
        if (pos >= bytes.len) return error.Truncated;
        const len = bytes[pos];
        pos += 1;
        if (pos + len > bytes.len) return error.Truncated;
        const name = try allocator.dupe(u8, bytes[pos .. pos + len]);
        errdefer allocator.free(name);
        pos += len;
        if (pos + 13 > bytes.len) return error.Truncated;
        const kind = @as(?EntityKind, @fromBackingInt(bytes[pos])) orelse return error.BadVersion;
        const first_seq = readU32be(bytes[pos + 1 .. pos + 5]).?;
        const last_seq = readU32be(bytes[pos + 5 .. pos + 9]).?;
        const count = readU32be(bytes[pos + 9 .. pos + 13]).?;
        pos += 13;
        try entities.append(allocator, .{
            .name = name,
            .kind = kind,
            .first_seq = first_seq,
            .last_seq = last_seq,
            .count = count,
        });
    }
    if (pos + records.DigestLen != bytes.len) return error.Truncated;
    var hasher = records.Sha256.init(.{});
    hasher.update(bytes[0..pos]);
    const digest = hasher.finalResult();
    if (!std.mem.eql(u8, &digest, bytes[pos..])) return error.BadFooter;

    const owned_words = try words.toOwnedSlice(allocator);
    const owned_entities = try entities.toOwnedSlice(allocator);
    // Success cleanup (errdefers are error-path only); nothing fallible
    // follows.
    freeWords(allocator, words.items);
    allocator.free(words.items);
    for (entities.items) |e| allocator.free(e.name);
    allocator.free(entities.items);
    return Index{
        .head = head,
        .record_count = record_count,
        .words = owned_words,
        .entities = owned_entities,
        .allocator = allocator,
    };
}

fn appendU64be(allocator: Allocator, b: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var tmp: [8]u8 = undefined;
    records.putU64(&tmp, v);
    try b.appendSlice(allocator, &tmp);
}

fn appendU32be(allocator: Allocator, b: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    records.putU32(&tmp, v);
    try b.appendSlice(allocator, &tmp);
}

fn readU64be(b: []const u8) ?u64 {
    if (b.len != 8) return null;
    var v: u64 = 0;
    for (b) |c| v = (v << 8) | c;
    return v;
}

fn readU32be(b: []const u8) ?u32 {
    if (b.len != 4) return null;
    var v: u32 = 0;
    for (b) |c| v = (v << 8) | c;
    return v;
}

// ---------------------------------------------------------------- digest

pub const DigestError = Allocator.Error || error{TimestampOutOfRange};

/// The digest's `top words` stopword list (spec/derived.md section 5):
/// a closed set of common English function words. Both implementations (Zig
/// and the Python gate) take it from the spec text; this const must match
/// it word for word. Affects `top words` counting only — the index,
/// `search`, and the `ask` question stopword list are untouched.
const DigestStopwords = [_][]const u8{
    "the",  "a",   "this", "that", "these", "those",  "my",    "our",   "your", "its",
    "i",    "me",  "we",   "us",   "you",   "he",     "she",   "it",    "they", "them",
    "be",   "am",  "is",   "are",  "was",   "were",   "been",  "being", "do",   "does",
    "have", "has", "had",  "will", "would", "should", "could", "may",   "must", "and",
    "or",   "but", "so",   "if",   "then",  "than",   "not",   "no",    "all",  "in",
    "on",   "at",  "to",   "of",   "for",   "with",   "by",    "from",  "as",
};

comptime {
    // The spec pins the list: 59 words, no duplicates.
    @setEvalBranchQuota(32_768);
    if (DigestStopwords.len != 59) @compileError("digest stopword list must hold 59 words (spec/derived.md section 5)");
    for (DigestStopwords, 0..) |a, i| {
        for (DigestStopwords[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) @compileError("duplicate digest stopword: " ++ a);
        }
    }
}

fn isDigestStopword(w: []const u8) bool {
    for (DigestStopwords) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}

/// The period's histograms: tag counts (tag bytes borrow from the payloads)
/// and word counts (owned bytes), both sorted count desc then name asc,
/// plus the in-range entries' days (ascending) and the period's top-5
/// kind-1 entities (owned names).
const DigestStats = struct {
    n: usize,
    redacted: usize,
    min_seq: u64,
    max_seq: u64,
    tags: []const TagCount,
    words: []const TagCount,
    days: []const i64,
    places: []const TagCount,
    allocator: Allocator,

    fn deinit(self: DigestStats) void {
        const allocator = self.allocator;
        allocator.free(self.tags);
        for (self.words) |wc| allocator.free(wc.tag);
        allocator.free(self.words);
        allocator.free(self.days);
        for (self.places) |pc| allocator.free(pc.tag);
        allocator.free(self.places);
    }
};

/// Computes the digest histograms for `range` (spec/derived.md section 5):
/// the tag histogram counts distinct entries, top words count token
/// occurrences over entry text. Pure in (visible, range).
fn digestStats(allocator: Allocator, visible: *const view.Visible, range: view.DayRange) DigestError!DigestStats {
    var tag_pairs = std.ArrayList(TagPair).empty;
    errdefer tag_pairs.deinit(allocator); // tag strings borrow from payloads
    var word_toks = std.ArrayList([]const u8).empty;
    errdefer {
        for (word_toks.items) |t| allocator.free(t);
        allocator.free(word_toks.items);
    }
    var word_counts = std.ArrayList(TagCount).empty;
    errdefer {
        for (word_counts.items) |wc| allocator.free(wc.tag);
        allocator.free(word_counts.items);
    }
    var days = std.ArrayList(i64).empty;
    errdefer days.deinit(allocator);
    var place_pairs = std.ArrayList(EntPair).empty; // names borrow from the payloads
    errdefer allocator.free(place_pairs.items);
    var n: usize = 0;
    var redacted: usize = 0;
    var min_seq: u64 = std.math.maxInt(u64);
    var max_seq: u64 = 0;
    for (visible.entries) |e| {
        if (e.day < range.start or e.day >= range.end) continue;
        n += 1;
        try days.append(allocator, e.day);
        if (e.redacted) {
            redacted += 1;
        } else {
            for (e.tags) |tag| try tag_pairs.append(allocator, .{ .tag = tag, .seq = e.seq });
            const sp = try tokens.spans(allocator, e.text);
            defer allocator.free(sp);
            for (sp) |s| {
                if (s.end - s.start < 2) continue;
                const low = try tokens.lowercase(allocator, e.text, s);
                if (isDigestStopword(low)) {
                    allocator.free(low); // stopword: not a top word
                    continue;
                }
                try word_toks.append(allocator, low);
            }
            // The period's kind-1 entities, one count per distinct name per
            // entry (the index is not consulted; spec/derived.md section 5).
            const runs = try phraseRuns(allocator, e.text, sp);
            defer allocator.free(runs);
            if (runs.len > 1) {
                var entry_runs = std.ArrayList([]const u8).empty;
                defer entry_runs.deinit(allocator);
                for (runs) |r| try entry_runs.append(allocator, r);
                std.mem.sort([]const u8, entry_runs.items, {}, tokenLessThan);
                for (entry_runs.items, 0..) |r, i| {
                    if (i > 0 and std.mem.eql(u8, entry_runs.items[i - 1], r)) continue;
                    if (r.len <= MaxNameLen) {
                        try place_pairs.append(allocator, .{ .name = r, .kind = .phrase, .seq = @intCast(e.seq) });
                    }
                }
            } else if (runs.len == 1) {
                if (runs[0].len <= MaxNameLen) {
                    try place_pairs.append(allocator, .{ .name = runs[0], .kind = .phrase, .seq = @intCast(e.seq) });
                }
            }
        }
        min_seq = @min(min_seq, e.seq);
        max_seq = @max(max_seq, e.seq);
    }
    // Group occurrences into (word, count) before any emission below.
    if (word_toks.items.len > 0) {
        std.mem.sort([]const u8, word_toks.items, {}, tokenLessThan);
        var i: usize = 0;
        while (i < word_toks.items.len) {
            const w = word_toks.items[i];
            var j = i;
            while (j < word_toks.items.len and std.mem.eql(u8, word_toks.items[j], w)) j += 1;
            const owned_w = try allocator.dupe(u8, w);
            errdefer allocator.free(owned_w);
            try word_counts.append(allocator, .{ .tag = owned_w, .count = @intCast(j - i) });
            i = j;
        }
    }
    std.mem.sort(TagPair, tag_pairs.items, {}, tagPairLessThan);
    var counts = std.ArrayList(TagCount).empty;
    errdefer counts.deinit(allocator); // tags borrow from payloads
    var i: usize = 0;
    while (i < tag_pairs.items.len) {
        const tag = tag_pairs.items[i].tag;
        var j = i;
        while (j < tag_pairs.items.len and std.mem.eql(u8, tag_pairs.items[j].tag, tag)) j += 1;
        try counts.append(allocator, .{ .tag = tag, .count = @intCast(j - i) });
        i = j;
    }
    std.mem.sort(TagCount, counts.items, {}, tagCountLessThan);
    std.mem.sort(TagCount, word_counts.items, {}, tagCountLessThan);
    // Places: group (name, seq) pairs sorted by name then seq; count = the
    // distinct entries carrying the name. The names are duped (they borrow
    // from the entry texts, which do not outlive this call).
    std.mem.sort(EntPair, place_pairs.items, {}, entPairLessThan);
    var place_counts = std.ArrayList(TagCount).empty;
    errdefer {
        for (place_counts.items) |pc| allocator.free(pc.tag);
        allocator.free(place_counts.items);
    }
    i = 0;
    while (i < place_pairs.items.len) {
        const name = place_pairs.items[i].name;
        var count: u32 = 0;
        var last: ?u32 = null;
        var j = i;
        while (j < place_pairs.items.len and std.mem.eql(u8, place_pairs.items[j].name, name)) {
            const s = place_pairs.items[j].seq;
            if (last != s) {
                count += 1;
                last = s;
            }
            j += 1;
        }
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try place_counts.append(allocator, .{ .tag = owned, .count = count });
        i = j;
    }
    std.mem.sort(TagCount, place_counts.items, {}, tagCountLessThan);
    const tags = try allocator.alloc(TagCount, counts.items.len);
    errdefer allocator.free(tags);
    const words = try allocator.alloc(TagCount, word_counts.items.len);
    errdefer allocator.free(words);
    const days_owned = try days.toOwnedSlice(allocator);
    errdefer allocator.free(days_owned);
    const top_places = place_counts.items[0..@min(5, place_counts.items.len)];
    const places = try allocator.alloc(TagCount, top_places.len);
    errdefer allocator.free(places);
    @memcpy(tags, counts.items);
    @memcpy(words, word_counts.items);
    @memcpy(places, top_places);
    // Success: nothing fallible follows; the grouping buffers are freed
    // explicitly (the errdefers are error-path only). The owned word bytes
    // live on in `words`, the place names in `places`, and both are freed
    // by DigestStats.deinit.
    counts.deinit(allocator);
    word_counts.deinit(allocator);
    tag_pairs.deinit(allocator);
    for (word_toks.items) |t| allocator.free(t);
    allocator.free(word_toks.items);
    allocator.free(place_pairs.items); // names borrow from the payloads
    for (place_counts.items[top_places.len..]) |pc| allocator.free(pc.tag);
    allocator.free(place_counts.items);
    return DigestStats{
        .n = n,
        .redacted = redacted,
        .min_seq = min_seq,
        .max_seq = max_seq,
        .tags = tags,
        .words = words,
        .days = days_owned,
        .places = places,
        .allocator = allocator,
    };
}

/// The digest display body (spec/derived.md section 5): the period line
/// (` – `, U+2013), a blank line, then `tags`, `top words` (stopword-
/// filtered, cap 10), `activity` (one pair per day of the period, cap 14
/// with a more-days note), and `people and places` (cap 5); an empty
/// period renders the period line alone.
fn renderDigestBodyFromStats(allocator: Allocator, stats: *const DigestStats, range: view.DayRange) DigestError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const d0 = view.civilDate(range.start) catch return error.TimestampOutOfRange;
    const d1 = view.civilDate(range.end - 1) catch return error.TimestampOutOfRange;
    try line(allocator, &out, "{d:0>4}-{d:0>2}-{d:0>2} \u{2013} {d:0>4}-{d:0>2}-{d:0>2} \u{B7} {d} {s}", .{
        d0.year, d0.month, d0.day, d1.year, d1.month, d1.day, stats.n, view.countNoun(stats.n, "entry", "entries"),
    });
    if (stats.redacted > 0) {
        try line(allocator, &out, " ({d} redacted)", .{stats.redacted});
    }
    try out.append(allocator, '\n');
    if (stats.n > 0) {
        var first_line = true; // one blank line before the first stat line
        if (stats.tags.len > 0) {
            if (first_line) {
                try out.append(allocator, '\n');
                first_line = false;
            }
            try out.appendSlice(allocator, "tags  ");
            for (stats.tags, 0..) |tc, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                try line(allocator, &out, "{s} {d}", .{ tc.tag, tc.count });
            }
            try out.append(allocator, '\n');
        }
        if (stats.words.len > 0) {
            if (first_line) {
                try out.append(allocator, '\n');
                first_line = false;
            }
            const top = stats.words[0..@min(10, stats.words.len)];
            try out.appendSlice(allocator, "top words  ");
            for (top, 0..) |tc, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                try line(allocator, &out, "{s} {d}", .{ tc.tag, tc.count });
            }
            try out.append(allocator, '\n');
        }
        // Activity: one pair per day of the period, at most 14, then a note.
        // stats.days is ascending, so a single pointer walk covers it.
        const n_days: i64 = range.end - range.start;
        const shown: i64 = @min(14, n_days);
        if (first_line) {
            try out.append(allocator, '\n');
            first_line = false;
        }
        try out.appendSlice(allocator, "activity  ");
        var ptr: usize = 0;
        var first_pair = true;
        var d: i64 = range.start;
        while (d < range.start + shown) : (d += 1) {
            while (ptr < stats.days.len and stats.days[ptr] < d) ptr += 1;
            var c: u32 = 0;
            while (ptr < stats.days.len and stats.days[ptr] == d) {
                c += 1;
                ptr += 1;
            }
            if (!first_pair) try out.appendSlice(allocator, ", ");
            first_pair = false;
            const cd = view.civilDate(d) catch return error.TimestampOutOfRange;
            try line(allocator, &out, "{d:0>4}-{d:0>2}-{d:0>2} {d}", .{ cd.year, cd.month, cd.day, c });
        }
        if (n_days > 14) {
            const more = @as(u64, @intCast(n_days - 14));
            try line(allocator, &out, ", \u{2026} {d} more {s}", .{ more, view.countNoun(more, "day", "days") });
        }
        try out.append(allocator, '\n');
        if (stats.places.len > 0) {
            if (first_line) {
                try out.append(allocator, '\n');
                first_line = false;
            }
            try out.appendSlice(allocator, "people and places  ");
            for (stats.places, 0..) |tc, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                try line(allocator, &out, "{s}", .{tc.tag});
            }
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Renders the digest display body for `range` (spec/derived.md section 5).
pub fn renderDigestBody(allocator: Allocator, visible: *const view.Visible, range: view.DayRange) DigestError![]u8 {
    const stats = try digestStats(allocator, visible, range);
    defer stats.deinit();
    return renderDigestBodyFromStats(allocator, &stats, range);
}

/// Renders the digest artifact for `range` (spec/derived.md section 5): the
/// machine header (format v2, period, seq range of the entries it covers,
/// head at build) followed by the display body.
pub fn renderDigest(
    allocator: Allocator,
    visible: *const view.Visible,
    range: view.DayRange,
    head: [records.DigestLen]u8,
) DigestError![]u8 {
    const stats = try digestStats(allocator, visible, range);
    defer stats.deinit();
    const d0 = view.civilDate(range.start) catch return error.TimestampOutOfRange;
    const d1 = view.civilDate(range.end - 1) catch return error.TimestampOutOfRange;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try line(allocator, &out, "# zephyr-digest: v2 period={d:0>4}-{d:0>2}-{d:0>2}..{d:0>4}-{d:0>2}-{d:0>2} range=seq {d}..{d} head={s}\n", .{
        d0.year,                               d0.month,                              d0.day,                         d1.year, d1.month, d1.day,
        if (stats.n > 0) stats.min_seq else 0, if (stats.n > 0) stats.max_seq else 0, try hexLower(allocator, &head),
    });
    const body = try renderDigestBodyFromStats(allocator, &stats, range);
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

const TagPair = struct { tag: []const u8, seq: u64 };
const TagCount = struct { tag: []const u8, count: u32 };

fn tagPairLessThan(_: void, a: TagPair, b: TagPair) bool {
    const o = std.mem.order(u8, a.tag, b.tag);
    if (o != .eq) return o == .lt;
    return a.seq < b.seq;
}

/// Count descending, then name ascending (digest tags and top words).
fn tagCountLessThan(_: void, a: TagCount, b: TagCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.tag, b.tag) == .lt;
}

fn line(allocator: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var buf: [1 << 16]u8 = undefined;
    const l = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    try out.appendSlice(allocator, l);
}

// ---------------------------------------------------------------- profile

pub const ProfileError = Allocator.Error || error{TimestampOutOfRange};

/// The number of redacted entries in `visible`.
fn redactedCount(visible: *const view.Visible) usize {
    var r: usize = 0;
    for (visible.entries) |e| {
        if (e.redacted) r += 1;
    }
    return r;
}

/// The earliest local day of `visible`, or null when empty.
fn firstDay(visible: *const view.Visible) ?i64 {
    if (visible.entries.len == 0) return null;
    var d: i64 = visible.entries[0].day;
    for (visible.entries) |e| d = @min(d, e.day);
    return d;
}

/// The fullest month across `visible` (earliest month wins ties), or null
/// when empty. The key's zero-based month index makes key % 12 the month.
fn bestMonth(allocator: Allocator, visible: *const view.Visible) ProfileError!?MonthCount {
    if (visible.entries.len == 0) return null;
    var months = std.ArrayList(MonthCount).empty;
    errdefer months.deinit(allocator);
    for (visible.entries) |e| {
        const d = view.civilDate(e.day) catch return error.TimestampOutOfRange;
        const key: i64 = @as(i64, @intCast(d.year)) * 12 + @as(i64, @intCast(d.month)) - 1;
        var found = false;
        for (months.items) |*m| {
            if (m.key == key) {
                m.count += 1;
                found = true;
                break;
            }
        }
        if (!found) try months.append(allocator, .{ .key = key, .count = 1 });
    }
    std.mem.sort(MonthCount, months.items, {}, monthKeyLessThan);
    var best: MonthCount = .{ .key = 0, .count = 0 };
    for (months.items) |m| {
        if (m.count > best.count) best = m; // earliest key wins ties (sorted)
    }
    const result: ?MonthCount = best;
    months.deinit(allocator); // success: nothing fallible follows
    return result;
}

/// The fullest weekday (ties win to the earlier weekday, Monday first), or
/// null when empty. Redacted entries count — the stat is over the entries'
/// days, not their text (spec/derived.md section 6).
fn bestWeekday(visible: *const view.Visible) ?u8 {
    if (visible.entries.len == 0) return null;
    var counts = std.mem.zeroes([7]u32);
    for (visible.entries) |e| {
        counts[view.weekdayIndex(e.day)] += 1;
    }
    var best: u8 = 0;
    for (counts, 0..) |c, i| {
        if (c > counts[best]) best = @intCast(i); // strict >: the earlier weekday wins ties
    }
    return best;
}

/// The fullest local-time band (ties win in the fixed order morning,
/// afternoon, evening, night), or null when empty. Redacted entries count.
fn bestTimeBand(visible: *const view.Visible) ?u32 {
    if (visible.entries.len == 0) return null;
    var counts = std.mem.zeroes([4]u32);
    for (visible.entries) |e| {
        counts[view.timeBand(view.hourOf(e.ts_ms, e.tz_offset_min))] += 1;
    }
    var best: u32 = 0;
    for (counts, 0..) |c, i| {
        if (c > counts[best]) best = @intCast(i); // strict >: the fixed band order wins ties
    }
    return best;
}

/// The longest run of consecutive civil days with at least one visible
/// entry; 0 for an empty journal. Redacted entries count. The entries are
/// sorted by day (view order), so one pass suffices.
fn longestStreak(visible: *const view.Visible) u32 {
    if (visible.entries.len == 0) return 0;
    var best: u32 = 0;
    var run: u32 = 0;
    var prev: ?i64 = null;
    for (visible.entries) |e| {
        if (prev) |p| {
            run = if (e.day == p + 1) run + 1 else if (e.day == p) run else 1;
        } else {
            run = 1;
        }
        if (run > best) best = run;
        prev = e.day;
    }
    return best;
}

/// The total token count (shared tokenizer, length ≥ 2) over the
/// non-redacted entries (spec/derived.md section 6).
fn totalWords(allocator: Allocator, visible: *const view.Visible) Allocator.Error!u64 {
    var total: u64 = 0;
    for (visible.entries) |e| {
        if (e.redacted) continue;
        const sp = try tokens.spans(allocator, e.text);
        defer allocator.free(sp);
        for (sp) |s| {
            if (s.end - s.start >= 2) total += 1;
        }
    }
    return total;
}

/// The top-10 kind-0 entities with counts, `name count` pairs joined with
/// ", " (count descending, then name ascending). The names borrow from
/// `entities`; the caller frees the joined string. Null when `entities`
/// holds none of the kind.
fn entityTagPairs(allocator: Allocator, entities: []const Entity) Allocator.Error!?[]u8 {
    var list = std.ArrayList(*const Entity).empty;
    errdefer list.deinit(allocator);
    for (entities) |*e| {
        if (@backingInt(e.kind) == 0) try list.append(allocator, e);
    }
    if (list.items.len == 0) return null;
    std.mem.sort(*const Entity, list.items, {}, entityCountLessThan);
    var pairs = std.ArrayList([]const u8).empty;
    errdefer pairs.deinit(allocator); // the pairs are owned copies
    var joined: ?[]u8 = null;
    errdefer if (joined) |s| allocator.free(s);
    for (list.items[0..@min(10, list.items.len)]) |e| {
        const pair = try std.fmt.allocPrint(allocator, "{s} {d}", .{ e.name, e.count });
        errdefer allocator.free(pair);
        try pairs.append(allocator, pair);
    }
    joined = try std.mem.join(allocator, ", ", pairs.items);
    // Success: nothing fallible follows; free both buffers explicitly so
    // the errdefers (error path only) don't double-free.
    pairs.deinit(allocator);
    list.deinit(allocator);
    return @as(?[]u8, joined);
}

/// The top-10 entity names of `kind` (0 = tag, 1 = phrase) — count
/// descending, then name ascending — joined with ", ". The names borrow
/// from `entities`; the caller frees the joined string. Null when
/// `entities` holds none of the kind.
fn entityNames(allocator: Allocator, entities: []const Entity, kind: u8) Allocator.Error!?[]u8 {
    var list = std.ArrayList(*const Entity).empty;
    errdefer list.deinit(allocator);
    for (entities) |*e| {
        if (@backingInt(e.kind) == kind) try list.append(allocator, e);
    }
    if (list.items.len == 0) return null;
    std.mem.sort(*const Entity, list.items, {}, entityCountLessThan);
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator); // the names borrow from `entities`
    for (list.items[0..@min(10, list.items.len)]) |e| try names.append(allocator, e.name);
    const joined = try std.mem.join(allocator, ", ", names.items);
    // Success: nothing fallible follows; free both buffers explicitly so
    // the errdefers (error path only) don't double-free.
    names.deinit(allocator);
    list.deinit(allocator);
    return @as(?[]u8, joined);
}

/// One stat line: the label padded with spaces to `width`, then the value.
fn statLine(allocator: Allocator, out: *std.ArrayList(u8), label: []const u8, width: usize, value: []const u8) Allocator.Error!void {
    try out.appendSlice(allocator, label);
    var pad = width - label.len;
    while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
    try out.appendSlice(allocator, value);
    try out.append(allocator, '\n');
}

/// Renders the profile display body (spec/derived.md section 6): the span
/// line (`{n} entries · {first-date} onward`, middle-dot U+00B7), a blank
/// line, and the stat block — labels padded to the longest label plus two
/// spaces, an empty stat an em dash (U+2014). An empty journal renders
/// `0 entries` alone.
pub fn renderProfileBody(
    allocator: Allocator,
    visible: *const view.Visible,
    entities: []const Entity,
) ProfileError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var tag_pairs: ?[]u8 = null;
    var place_names: ?[]u8 = null;
    errdefer {
        if (tag_pairs) |s| allocator.free(s);
        if (place_names) |s| allocator.free(s);
    }
    const n: u64 = @intCast(visible.entries.len);
    if (n == 0) {
        try line(allocator, &out, "0 entries\n", .{});
    } else {
        const first = view.civilDate(firstDay(visible).?) catch return error.TimestampOutOfRange;
        const best = (try bestMonth(allocator, visible)).?;
        try line(allocator, &out, "{d} {s} \u{B7} {d:0>4}-{d:0>2}-{d:0>2} onward", .{
            n, view.countNoun(n, "entry", "entries"), first.year, first.month, first.day,
        });
        const r = redactedCount(visible);
        if (r > 0) try line(allocator, &out, " ({d} redacted)", .{r});
        try out.append(allocator, '\n');
        try out.append(allocator, '\n'); // blank line before the stat block
        tag_pairs = try entityTagPairs(allocator, entities);
        place_names = try entityNames(allocator, entities, 1);
        // All seven labels are always present, so the longest decides the
        // column width.
        const width = @max("most active".len, @max("time of day".len, "people and places".len)) + 2;
        var vbuf: [24]u8 = undefined;
        const month = std.fmt.bufPrint(&vbuf, "{d:0>4}-{d:0>2}", .{
            @as(u64, @intCast(@divTrunc(best.key, 12))), @as(u64, @intCast(@mod(best.key, 12))) + 1,
        }) catch unreachable;
        try statLine(allocator, &out, "most active", width, month);
        try statLine(allocator, &out, "weekday", width, view.Weekdays[bestWeekday(visible).?]);
        const bands = [_][]const u8{ "morning", "afternoon", "evening", "night" };
        try statLine(allocator, &out, "time of day", width, bands[bestTimeBand(visible).?]);
        const streak = longestStreak(visible);
        const streak_v = std.fmt.bufPrint(&vbuf, "{d} {s}", .{ streak, view.countNoun(streak, "day", "days") }) catch unreachable;
        try statLine(allocator, &out, "streak", width, streak_v);
        const total = try totalWords(allocator, visible);
        const avg_v = std.fmt.bufPrint(&vbuf, "{d}", .{(total / n)}) catch unreachable;
        try statLine(allocator, &out, "avg words", width, avg_v);
        try statLine(allocator, &out, "tags", width, tag_pairs orelse "\u{2014}");
        try statLine(allocator, &out, "people and places", width, place_names orelse "\u{2014}");
    }
    return out.toOwnedSlice(allocator);
}

/// Renders the profile artifact (spec/derived.md section 6): the machine
/// header (format v3, the journal's seq range, head at build) followed by
/// the display body.
pub fn renderProfile(
    allocator: Allocator,
    visible: *const view.Visible,
    entities: []const Entity,
    record_count: u64,
    head: [records.DigestLen]u8,
) ProfileError![]u8 {
    const head_hex = try hexLower(allocator, &head);
    defer allocator.free(head_hex);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (record_count > 0) {
        try line(allocator, &out, "# zephyr-profile: v3 range=seq 0..{d} head={s}\n", .{ record_count - 1, head_hex });
    } else {
        try line(allocator, &out, "# zephyr-profile: v3 range=none head={s}\n", .{head_hex});
    }
    const body = try renderProfileBody(allocator, visible, entities);
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

const MonthCount = struct { key: i64, count: u32 };

fn monthKeyLessThan(_: void, a: MonthCount, b: MonthCount) bool {
    return a.key < b.key;
}

/// Count descending, then name ascending (profile entity sections).
fn entityCountLessThan(_: void, a: *const Entity, b: *const Entity) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// ---------------------------------------------------------------- tests

const D0: i64 = 20454; // 2026-01-01
const D1: i64 = 20494; // 2026-02-10
const HEAD: [records.DigestLen]u8 = @splat(0xAB);

fn mkVisible(allocator: Allocator, entries: []const view.ViewEntry) Allocator.Error!view.Visible {
    var tl = std.ArrayList([]const []const u8).empty;
    errdefer tl.deinit(allocator);
    for (entries) |e| {
        const copy = try allocator.alloc([]const u8, e.tags.len);
        errdefer allocator.free(copy);
        for (copy, e.tags) |*slot, tag| slot.* = tag;
        try tl.append(allocator, copy);
    }
    const owned = try allocator.alloc(view.ViewEntry, entries.len);
    errdefer allocator.free(owned);
    @memcpy(owned, entries);
    const owned_tl = try tl.toOwnedSlice(allocator);
    errdefer allocator.free(owned_tl);
    return view.Visible{
        .entries = owned,
        .tag_lists = owned_tl,
        .allocator = allocator,
    };
}

fn fixtureEntries() []const view.ViewEntry {
    return &.{
        .{ .seq = 0, .ts_ms = 1_767_229_200_000, .tz_offset_min = 0, .day = D0, .redacted = false, .edited = false, .text = "shipped the auth fix", .tags = &.{"work"} },
        .{ .seq = 1, .ts_ms = 1_767_240_000_000, .tz_offset_min = 0, .day = D0, .redacted = false, .edited = false, .text = "walked the dog", .tags = &.{} },
        .{ .seq = 2, .ts_ms = 1_767_250_800_000, .tz_offset_min = 0, .day = D0, .redacted = true, .edited = false, .text = "", .tags = &.{} },
        .{ .seq = 3, .ts_ms = 1_770_000_000_000, .tz_offset_min = 0, .day = D1, .redacted = false, .edited = false, .text = "met Alice in New York", .tags = &.{"Alice"} },
    };
}

test "index: build, encode, decode round trip and determinism" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vis = try mkVisible(allocator, fixtureEntries());
    defer vis.deinit();
    const idx = try buildIndex(allocator, &vis, HEAD, 4);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u64, 4), idx.record_count);
    try std.testing.expectEqual(@as(usize, 12), idx.words.len);
    const the = idx.lookupWord("the").?;
    try std.testing.expectEqual(@as(usize, 2), the.len);
    try std.testing.expectEqual(@as(u32, 0), the[0]);
    try std.testing.expectEqual(@as(u32, 1), the[1]);
    try std.testing.expectEqual(@as(usize, 1), idx.lookupWord("alice").?.len);
    try std.testing.expect(idx.lookupWord("zebra") == null);
    // Tag+phrase merge: "Alice" appears as tag and phrase in one entry.
    try std.testing.expectEqual(@as(usize, 3), idx.entities.len);
    try std.testing.expectEqualStrings("Alice", idx.entities[0].name);
    try std.testing.expect(idx.entities[0].kind == .tag);
    try std.testing.expectEqual(@as(u32, 1), idx.entities[0].count);
    try std.testing.expectEqualStrings("New York", idx.entities[1].name);
    try std.testing.expect(idx.entities[1].kind == .phrase);
    try std.testing.expectEqualStrings("work", idx.entities[2].name);

    // Encode/decode round trip.
    const bytes = try encodeIndex(allocator, &idx);
    defer allocator.free(bytes);
    const back = try decodeIndex(allocator, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, idx.words.len), back.words.len);
    for (idx.words) |w| {
        const bw = back.lookupWord(w.word).?;
        try std.testing.expectEqualSlices(u32, w.seqs, bw);
    }
    try std.testing.expectEqual(@as(usize, idx.entities.len), back.entities.len);

    // Determinism: a fresh build encodes to identical bytes.
    const vis2 = try mkVisible(allocator, fixtureEntries());
    defer vis2.deinit();
    const idx2 = try buildIndex(allocator, &vis2, HEAD, 4);
    defer idx2.deinit();
    const bytes2 = try encodeIndex(allocator, &idx2);
    defer allocator.free(bytes2);
    try std.testing.expectEqualSlices(u8, bytes, bytes2);
}

test "index: decode rejects corruption" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vis = try mkVisible(allocator, fixtureEntries());
    defer vis.deinit();
    const idx = try buildIndex(allocator, &vis, HEAD, 4);
    defer idx.deinit();
    const bytes = try encodeIndex(allocator, &idx);
    defer allocator.free(bytes);

    var flipped = try allocator.dupe(u8, bytes);
    defer allocator.free(flipped);
    flipped[40] ^= 0x01; // inside the word section
    try std.testing.expectError(error.BadFooter, decodeIndex(allocator, flipped));

    flipped = try allocator.dupe(u8, bytes);
    defer allocator.free(flipped);
    flipped[0] ^= 0xFF; // bad magic
    try std.testing.expectError(error.BadMagic, decodeIndex(allocator, flipped));

    try std.testing.expectError(error.Truncated, decodeIndex(allocator, bytes[0 .. bytes.len - 1]));
}

test "index: dedup within an entry, long runs ignored, stopwords" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]view.ViewEntry{.{
        .seq = 0,
        .ts_ms = 1_767_229_200_000,
        .tz_offset_min = 0,
        .day = D0,
        .redacted = false,
        .edited = false,
        .text = "zephyr zephyr ZEPHYR New York City Hall, Park arrived on Monday",
        .tags = &.{},
    }};
    const vis = try mkVisible(allocator, &entries);
    defer vis.deinit();
    const idx = try buildIndex(allocator, &vis, HEAD, 1);
    defer idx.deinit();

    // "zephyr" and "ZEPHYR" collapse to one lowercase word, once per entry.
    const z = idx.lookupWord("zephyr").?;
    try std.testing.expectEqual(@as(usize, 1), z.len);
    try std.testing.expectEqual(@as(u32, 0), z[0]);
    // The comma breaks the 5-word run into "New York City Hall" (kept) and
    // "Park" (kept); "Monday" is a stopword.
    try std.testing.expectEqual(@as(usize, 2), idx.entities.len);
    try std.testing.expectEqualStrings("New York City Hall", idx.entities[0].name);
    try std.testing.expect(idx.entities[0].kind == .phrase);
    try std.testing.expectEqualStrings("Park", idx.entities[1].name);
}

test "digest: exact bytes for a fixed period" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vis = try mkVisible(allocator, fixtureEntries());
    defer vis.deinit();
    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    const got = try renderDigest(allocator, &vis, range, HEAD);
    defer allocator.free(got);
    const want = try allocator.print(
        "# zephyr-digest: v2 period=2026-01-01..2026-01-01 range=seq 0..2 head={s}\n" ++
            "2026-01-01 \u{2013} 2026-01-01 \u{B7} 3 entries (1 redacted)\n" ++
            "\n" ++
            "tags  work 1\n" ++
            // "the" (x2) is a digest stopword and does not appear.
            "top words  auth 1, dog 1, fix 1, shipped 1, walked 1\n" ++
            "activity  2026-01-01 3\n",
        .{try hexLower(allocator, &HEAD)},
    );
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "digest: top words absent when every token is a stopword" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]view.ViewEntry{.{
        .seq = 0,
        .ts_ms = 1_767_229_200_000,
        .tz_offset_min = 0,
        .day = D0,
        .redacted = false,
        .edited = false,
        .text = "the and of to in",
        .tags = &.{},
    }};
    const vis = try mkVisible(allocator, &entries);
    defer vis.deinit();
    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    const got = try renderDigest(allocator, &vis, range, HEAD);
    defer allocator.free(got);
    const want = try allocator.print(
        "# zephyr-digest: v2 period=2026-01-01..2026-01-01 range=seq 0..0 head={s}\n" ++
            "2026-01-01 \u{2013} 2026-01-01 \u{B7} 1 entry\n" ++
            "\n" ++
            "activity  2026-01-01 1\n",
        .{try hexLower(allocator, &HEAD)},
    );
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "digest: activity caps at 14 pairs with a more-days note" {
    // Synthetic stats over a 20-day period: one entry on the first and one
    // on the last day. The last entry is outside the shown window, so the
    // note carries the remainder.
    const allocator = std.testing.allocator;
    const stats = DigestStats{
        .n = 2,
        .redacted = 0,
        .min_seq = 0,
        .max_seq = 1,
        .tags = &.{},
        .words = &.{},
        .days = &[_]i64{ D0, D0 + 19 },
        .places = &.{},
        .allocator = allocator,
    };
    const range = view.DayRange{ .start = D0, .end = D0 + 20 };
    const body = try renderDigestBodyFromStats(allocator, &stats, range);
    defer allocator.free(body);
    const want = try std.testing.allocator.print(
        "2026-01-01 \u{2013} 2026-01-20 \u{B7} 2 entries\n" ++
            "\n" ++
            "activity  2026-01-01 1, " ++
            "2026-01-02 0, 2026-01-03 0, 2026-01-04 0, 2026-01-05 0, " ++
            "2026-01-06 0, 2026-01-07 0, 2026-01-08 0, 2026-01-09 0, " ++
            "2026-01-10 0, 2026-01-11 0, 2026-01-12 0, 2026-01-13 0, " ++
            "2026-01-14 0, \u{2026} 6 more days\n",
        .{},
    );
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, body);
}

test "digest: empty period renders header and 0 entries" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vis = try mkVisible(allocator, fixtureEntries());
    defer vis.deinit();
    const range = view.DayRange{ .start = 20485, .end = 20486 }; // 2026-02-01
    const got = try renderDigest(allocator, &vis, range, HEAD);
    defer allocator.free(got);
    const want = try allocator.print(
        "# zephyr-digest: v2 period=2026-02-01..2026-02-01 range=seq 0..0 head={s}\n" ++
            "2026-02-01 \u{2013} 2026-02-01 \u{B7} 0 entries\n",
        .{try hexLower(allocator, &HEAD)},
    );
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "profile: exact bytes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vis = try mkVisible(allocator, fixtureEntries());
    defer vis.deinit();
    const idx = try buildIndex(allocator, &vis, HEAD, 4);
    defer idx.deinit();
    const got = try renderProfile(allocator, &vis, idx.entities, 4, HEAD);
    defer allocator.free(got);
    // Hours 1, 4 -> night, 7 -> morning, 2 -> night; days D0 (x3) and D1
    // are not consecutive; 12 tokens over 4 entries.
    const want = try allocator.print(
        "# zephyr-profile: v3 range=seq 0..3 head={s}\n" ++
            "4 entries \u{B7} 2026-01-01 onward (1 redacted)\n" ++
            "\n" ++
            "most active        2026-01\n" ++
            "weekday            Thu\n" ++
            "time of day        night\n" ++
            "streak             1 day\n" ++
            "avg words          3\n" ++
            "tags               Alice 1, work 1\n" ++
            "people and places  New York\n",
        .{try hexLower(allocator, &HEAD)},
    );
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "profile: empty journal" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vis = try mkVisible(allocator, &[_]view.ViewEntry{});
    defer vis.deinit();
    const genesis = records.Header.GenesisHash;
    const got = try renderProfile(allocator, &vis, &.{}, 0, genesis);
    defer allocator.free(got);
    const want = try allocator.print(
        "# zephyr-profile: v3 range=none head={s}\n" ++ "0 entries\n",
        .{try hexLower(allocator, &genesis)},
    );
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "profile: streak, weekday and band tie-breaks" {
    // Thu 06:00 (morning) and Fri 23:00 (night): the weekday tie goes to
    // the earlier weekday, the band tie to the fixed order, and the two
    // consecutive days form a 2-day streak.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]view.ViewEntry{
        .{
            .seq = 0,
            .ts_ms = 1_767_247_200_000, // 2026-01-01T06:00Z
            .tz_offset_min = 0,
            .day = D0,
            .redacted = false,
            .edited = false,
            .text = "one two three",
            .tags = &.{},
        },
        .{
            .seq = 1,
            .ts_ms = 1_767_394_800_000, // 2026-01-02T23:00Z
            .tz_offset_min = 0,
            .day = D0 + 1,
            .redacted = false,
            .edited = false,
            .text = "four five",
            .tags = &.{},
        },
    };
    const vis = try mkVisible(allocator, &entries);
    defer vis.deinit();
    const got = try renderProfile(allocator, &vis, &.{}, 2, HEAD);
    defer allocator.free(got);
    const want = try allocator.print(
        "# zephyr-profile: v3 range=seq 0..1 head={s}\n" ++
            "2 entries \u{B7} 2026-01-01 onward\n" ++
            "\n" ++
            "most active        2026-01\n" ++
            "weekday            Thu\n" ++
            "time of day        morning\n" ++
            "streak             2 days\n" ++
            "avg words          2\n" ++
            "tags               \u{2014}\n" ++
            "people and places  \u{2014}\n",
        .{try hexLower(allocator, &HEAD)},
    );
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "phrase rules: sentence starts, stopwords, runs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = "The Zephyr was fun. I saw Berlin. New Berlin rose";
    const sp = try tokens.spans(allocator, text);
    defer allocator.free(sp);
    const runs = try phraseRuns(allocator, text, sp);
    defer allocator.free(runs);
    // "The" begins the text and "New" follows ". ", so neither qualifies.
    // Both "Berlin"s are mid-sentence (the second one follows "New") and
    // qualify; runs are per occurrence.
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try std.testing.expectEqualStrings("Zephyr", runs[0]);
    try std.testing.expectEqualStrings("Berlin", runs[1]);
    try std.testing.expectEqualStrings("Berlin", runs[2]);
}
