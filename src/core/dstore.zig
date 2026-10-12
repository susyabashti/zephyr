//! On-disk store of the derived layer (spec/derived.md section 2): the
//! `derived/` directory, `profile.md` and `notes.md`, the staleness
//! protocol, legacy-profile migration, and the context pack behind
//! `zephyr ask` and the `get_context` MCP tool.
//!
//! Artifacts are pure functions of the verified log (derived.zig); this
//! module decides when they are fresh (head binding) and rewrites them on
//! read when stale. The journal reader only loads `<YYYY>-<MM>.zph` names,
//! so none of these files can affect verify.

const std = @import("std");
const Io = std.Io;
const journal_mod = @import("journal.zig");
const derived = @import("derived.zig");
const records = @import("records.zig");
const search = @import("search.zig");
const segment = @import("segment.zig");
const tokens = @import("tokens.zig");
const timezone = @import("timezone.zig");
const view = @import("view.zig");

const Allocator = std.mem.Allocator;

pub const DerivedDir = "derived";
pub const DigestsDir = "derived/digests";
pub const IndexFile = "derived/index.zdi";
pub const ProfileFile = "profile.md";
pub const NotesFile = "notes.md";
pub const ProfileHeader = "# zephyr-profile: v1 ";

/// Default cap on the pack's rendered match lines (spec/derived.md section 7).
pub const PackMatchCap: usize = 8 << 10;

pub const IoError = Io.Dir.ReadFileAllocError || Io.Dir.CreateDirPathError || segment.WriteError;

// ---------------------------------------------------------------- small I/O

/// Reads a file of the journal directory, or null when it does not exist.
fn readJournalOrNull(allocator: Allocator, journal: *const journal_mod.Journal, name: []const u8) Io.Dir.ReadFileAllocError!?[]u8 {
    return journal.readJournalFile(allocator, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

/// True when `doc`'s first line ends with `head=<64-hex of head>`.
fn headLineMatches(allocator: Allocator, doc: []const u8, head: [records.DigestLen]u8) Allocator.Error!bool {
    const line_end = std.mem.indexOfScalar(u8, doc, '\n') orelse return doc.len > 0;
    const first = doc[0..line_end];
    const hex = try derived.hexLower(allocator, &head);
    defer allocator.free(hex);
    const suffix = try allocator.print("head={s}", .{hex});
    defer allocator.free(suffix);
    return std.mem.endsWith(u8, first, suffix);
}

// ---------------------------------------------------------------- index

/// The index when fresh (present, decodable, bound to `result.head`);
/// null when missing, stale, or corrupt (spec/derived.md section 2: a
/// corrupted artifact is indistinguishable from a stale one and simply
/// gets rebuilt — never an error).
pub fn loadFreshIndex(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    result: journal_mod.VerifyResult,
) (Allocator.Error || Io.Dir.ReadFileAllocError || derived.DecodeIndexError)!?derived.Index {
    const bytes = (try readJournalOrNull(allocator, journal, IndexFile)) orelse return null;
    defer allocator.free(bytes);
    const idx = derived.decodeIndex(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (!std.mem.eql(u8, &idx.head, &result.head)) {
        idx.deinit();
        return null;
    }
    return idx;
}

pub fn saveIndex(allocator: Allocator, journal: *const journal_mod.Journal, idx: derived.Index) (Allocator.Error || IoError)!void {
    try Io.Dir.createDirPath(journal.dir, journal.io, DerivedDir);
    const bytes = try derived.encodeIndex(allocator, &idx);
    defer allocator.free(bytes);
    try segment.writeAtomic(journal.dir, journal.io, IndexFile, bytes);
}

// ---------------------------------------------------------------- digests

/// `derived/digests/<start>_<end>.digest` for the period.
pub fn digestFileName(allocator: Allocator, range: view.DayRange) (Allocator.Error || error{TimestampOutOfRange})![]const u8 {
    const d0 = view.civilDate(range.start) catch return error.TimestampOutOfRange;
    const d1 = view.civilDate(range.end - 1) catch return error.TimestampOutOfRange;
    return allocator.print(
        DigestsDir ++ "/{d:0>4}-{d:0>2}-{d:0>2}_{d:0>4}-{d:0>2}-{d:0>2}.digest",
        .{ d0.year, d0.month, d0.day, d1.year, d1.month, d1.day },
    );
}

/// The stored digest for `range` when fresh; null when missing, stale, or
/// unreadable.
pub fn loadFreshDigest(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    range: view.DayRange,
    result: journal_mod.VerifyResult,
) (Allocator.Error || Io.Dir.ReadFileAllocError || error{TimestampOutOfRange})!?[]u8 {
    const name = try digestFileName(allocator, range);
    defer allocator.free(name);
    const doc = (try readJournalOrNull(allocator, journal, name)) orelse return null;
    const fresh = try headLineMatches(allocator, doc, result.head);
    if (!fresh) {
        allocator.free(doc);
        return null;
    }
    return doc;
}

pub fn saveDigest(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    range: view.DayRange,
    bytes: []const u8,
) (Allocator.Error || IoError || error{TimestampOutOfRange})!void {
    try Io.Dir.createDirPath(journal.dir, journal.io, DigestsDir);
    const name = try digestFileName(allocator, range);
    defer allocator.free(name);
    try segment.writeAtomic(journal.dir, journal.io, name, bytes);
}

// ---------------------------------------------------------------- profile

/// The stored profile when fresh; null when missing, stale, corrupt, or
/// still a pre-Phase-7 document (run `migrateLegacyProfile` first).
pub fn loadFreshProfile(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    result: journal_mod.VerifyResult,
) (Allocator.Error || Io.Dir.ReadFileAllocError)!?[]u8 {
    const doc = (try readJournalOrNull(allocator, journal, ProfileFile)) orelse return null;
    if (!std.mem.startsWith(u8, doc, ProfileHeader)) {
        allocator.free(doc);
        return null;
    }
    const fresh = try headLineMatches(allocator, doc, result.head);
    if (!fresh) {
        allocator.free(doc);
        return null;
    }
    return doc;
}

pub fn saveProfile(journal: *const journal_mod.Journal, bytes: []const u8) IoError!void {
    try segment.writeAtomic(journal.dir, journal.io, ProfileFile, bytes);
}

/// Moves a pre-Phase-7 hand-written profile.md into notes.md (spec/derived.md
/// section 6): the legacy text is appended to the existing notes (blank line
/// between) or written as notes.md. Idempotent — a versioned profile or a
/// missing file is a no-op.
pub fn migrateLegacyProfile(allocator: Allocator, journal: *const journal_mod.Journal) IoError!void {
    const doc = (try readJournalOrNull(allocator, journal, ProfileFile)) orelse return;
    defer allocator.free(doc);
    if (std.mem.startsWith(u8, doc, ProfileHeader)) return;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if ((try readJournalOrNull(allocator, journal, NotesFile))) |notes| {
        defer allocator.free(notes);
        try out.appendSlice(allocator, notes);
        if (notes.len > 0 and notes[notes.len - 1] != '\n') try out.append(allocator, '\n');
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, doc);
    try segment.writeAtomic(journal.dir, journal.io, NotesFile, out.items);
    allocator.free(out.items);
}

// ---------------------------------------------------------------- context pack

pub const PackError = Allocator.Error || IoError || derived.BuildIndexError ||
    derived.DecodeIndexError || derived.DigestError || derived.ProfileError ||
    search.RenderError || error{TimestampOutOfRange};

/// Assembles the context pack (spec/derived.md section 7): provenance,
/// question, derived profile, notes, the period digest (when `range` is set),
/// keyword matches, and the answer footer. `result` must be the journal's
/// current verify result. `persist` controls whether stale or missing
/// artifacts are written back (CLI) or computed in memory only (MCP);
/// migration runs only when `persist` is set.
pub fn contextPack(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    visible: *const view.Visible,
    result: journal_mod.VerifyResult,
    question: []const u8,
    range: ?view.DayRange,
    persist: bool,
) PackError![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    errdefer {
        for (parts.items) |p| allocator.free(p);
        allocator.free(parts.items);
    }
    const head_hex = try derived.hexLower(allocator, &result.head);
    defer allocator.free(head_hex);

    // 1. Provenance line (same shape as the MCP server and the LLM view).
    const last_seq: u64 = if (result.record_count == 0) 0 else result.record_count - 1;
    const prov = try allocator.print("# zephyr: seq 0..{d} head={s}\n", .{ last_seq, head_hex });
    try parts.append(allocator, prov);

    // 2. Question verbatim.
    const q = try allocator.print("# question: {s}\n", .{question});
    try parts.append(allocator, q);

    // 3. Index (retrieval + profile entities): fresh from disk or rebuilt.
    const idx = (try loadFreshIndex(allocator, journal, result)) orelse blk: {
        const fresh = try derived.buildIndex(allocator, visible, result.head, result.record_count);
        if (persist) try saveIndex(allocator, journal, fresh);
        break :blk fresh;
    };
    defer idx.deinit();

    // 4. Profile (persist: migrate a legacy document first, then rewrite).
    if (persist) try migrateLegacyProfile(allocator, journal);
    const profile = (try loadFreshProfile(allocator, journal, result)) orelse blk: {
        const fresh = try derived.renderProfile(allocator, visible, idx.entities, result.record_count, result.head);
        if (persist) try saveProfile(journal, fresh);
        break :blk fresh;
    };
    try parts.append(allocator, profile);

    // 5. Notes, under a heading so the AI can tell machine from voice.
    if ((try readJournalOrNull(allocator, journal, NotesFile))) |notes| {
        const joined = blk: {
            const sep = if (notes.len > 0 and notes[notes.len - 1] != '\n') "\n" else "";
            break :blk try allocator.print("# notes\n{s}{s}", .{ notes, sep });
        };
        allocator.free(notes);
        try parts.append(allocator, joined);
    }

    // 6. Digest for the resolved period (fresh from disk or rebuilt).
    if (range) |r| {
        const digest = (try loadFreshDigest(allocator, journal, r, result)) orelse blk: {
            const fresh = try derived.renderDigest(allocator, visible, r, result.head);
            if (persist) try saveDigest(allocator, journal, r, fresh);
            break :blk fresh;
        };
        try parts.append(allocator, digest);
    }

    // 7. Keyword retrieval: question tokens (stopwords removed) through the
    //    index; scoped to the period when one was resolved.
    const matches = try retrieve(allocator, visible, &idx, question, range, result.record_count);
    if (matches.len > 0) {
        const rendered = try search.renderCapped(allocator, matches, question, PackMatchCap);
        allocator.free(matches);
        try parts.append(allocator, rendered);
    }

    // 8. Answer footer. (Allocated: every part of the pack is a real
    //    allocation, so the uniform free below is exact.)
    const footer = try allocator.dupe(u8, "Answer using only the entries above; cite seqs; say so if the " ++
        "answer is not present.\n");
    try parts.append(allocator, footer);

    // Join, then release the parts (errdefers are error-path only; nothing
    // fallible follows).
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (parts.items) |p| try out.appendSlice(allocator, p);
    const result_bytes = try out.toOwnedSlice(allocator);
    for (parts.items) |p| allocator.free(p);
    allocator.free(parts.items);
    return result_bytes;
}

/// Question tokens (shared tokenizer, stopwords removed, deduplicated,
/// lowercased) looked up in the index; the union of their seqs as matches
/// in view order, scoped to `range` when set. Public: the Phase 7 gate
/// cross-checks it against a brute-force token scan (spec/derived.md
/// section 8), and `contextPack` renders its result.
pub fn retrieve(
    allocator: Allocator,
    visible: *const view.Visible,
    idx: *const derived.Index,
    question: []const u8,
    range: ?view.DayRange,
    record_count: u64,
) PackError![]search.Match {
    const sp = try tokens.spans(allocator, question);
    defer allocator.free(sp);
    var qwords = std.ArrayList([]const u8).empty;
    errdefer {
        for (qwords.items) |w| allocator.free(w);
        allocator.free(qwords.items);
    }
    var i: usize = 0;
    while (i < sp.len) {
        if (i > 0 and std.mem.eql(u8, tokens.token(question, sp[i - 1]), tokens.token(question, sp[i]))) {
            i += 1;
            continue;
        }
        if (sp[i].end - sp[i].start < 2) {
            i += 1;
            continue;
        }
        if (tokens.isStopword(question, sp[i], &tokens.QuestionStopwords)) {
            i += 1;
            continue;
        }
        try qwords.append(allocator, try tokens.lowercase(allocator, question, sp[i]));
        i += 1;
    }

    var matched = try allocator.alloc(bool, record_count);
    errdefer allocator.free(matched);
    @memset(matched, false);
    for (qwords.items) |w| {
        if (idx.lookupWord(w)) |seqs| {
            for (seqs) |seq| matched[seq] = true;
        }
    }
    var matches = std.ArrayList(search.Match).empty;
    errdefer matches.deinit(allocator);
    for (visible.entries) |e| {
        if (e.redacted or !matched[e.seq]) continue;
        if (range) |r| {
            if (e.day < r.start or e.day >= r.end) continue;
        }
        try matches.append(allocator, .{
            .seq = e.seq,
            .day = e.day,
            .ts_ms = e.ts_ms,
            .tz_offset_min = e.tz_offset_min,
            .text = e.text,
            .tags = e.tags,
        });
    }
    // All fallible work is done: free the scratch on the success path (the
    // errdefers above are error-path only, so reset the scratch to make them
    // no-ops), then hand off the owned slice.
    for (qwords.items) |w| allocator.free(w);
    allocator.free(qwords.items);
    qwords.items = &.{};
    qwords.capacity = 0;
    allocator.free(matched);
    matched = &.{};
    return matches.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- period resolution

pub const ResolveRangeError = timezone.LoadError || error{ TimestampOutOfRange, TzOutOfRange };

/// The civil day of `s` when it is a valid `YYYY-MM-DD`; null otherwise.
pub fn civilDateOf(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u64, s[8..10], 10) catch return null;
    return view.dateToCivilDay(year, month, day);
}

/// The civil day of the first `YYYY-MM-DD` occurring in `text`, if any
/// (spec/derived.md section 7: an ISO date in the question covers that day).
pub fn firstIsoDate(text: []const u8) ?i64 {
    var i: usize = 0;
    while (i + 10 <= text.len) : (i += 1) {
        if (text[i + 4] == '-' and text[i + 7] == '-') {
            if (civilDateOf(text[i .. i + 10])) |d| return d;
        }
    }
    return null;
}

/// The pack's period (spec/derived.md section 7, step 4): the explicit
/// range when given, else the day of the first ISO date in the question,
/// else the current week (Mon-Sun) under the journal's timezone.
pub fn resolveRange(
    io: Io,
    journal: *const journal_mod.Journal,
    range: ?view.DayRange,
    question: []const u8,
) ResolveRangeError!view.DayRange {
    if (range) |r| return r;
    if (firstIsoDate(question)) |day| {
        return view.DayRange{ .start = day, .end = day + 1 };
    }
    const ms = Io.Timestamp.now(io, .real).toMilliseconds();
    if (ms < 0) return error.TimestampOutOfRange;
    const now: u64 = @intCast(ms);
    const tz = try journal.tzOffsetMinutesAtMs(now);
    const today = try view.localDay(now, tz);
    const monday = view.weekStart(today);
    return view.DayRange{ .start = monday, .end = monday + 7 };
}

// ---------------------------------------------------------------- digest or rebuild

/// The stored digest for `range` when fresh; otherwise rendered and
/// stored. Backs `zephyr recap`.
pub fn digestOrRebuild(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    visible: *const view.Visible,
    range: view.DayRange,
    result: journal_mod.VerifyResult,
) (Allocator.Error || IoError || derived.DigestError || error{TimestampOutOfRange})![]u8 {
    if (try loadFreshDigest(allocator, journal, range, result)) |doc| return doc;
    const fresh = try derived.renderDigest(allocator, visible, range, result.head);
    try saveDigest(allocator, journal, range, fresh);
    return fresh;
}

// ---------------------------------------------------------------- profile + notes

/// The derived profile (stored when stale or missing, a legacy document
/// migrated first) followed by the user's notes under `# notes`, or a
/// one-line note when `notes.md` is absent (spec/derived.md section 6).
/// Backs `zephyr profile`.
pub fn profileWithNotes(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    visible: *const view.Visible,
    result: journal_mod.VerifyResult,
) PackError![]u8 {
    try migrateLegacyProfile(allocator, journal);
    const idx = (try loadFreshIndex(allocator, journal, result)) orelse blk: {
        const fresh = try derived.buildIndex(allocator, visible, result.head, result.record_count);
        try saveIndex(allocator, journal, fresh);
        break :blk fresh;
    };
    defer idx.deinit();
    const profile = (try loadFreshProfile(allocator, journal, result)) orelse blk: {
        const fresh = try derived.renderProfile(allocator, visible, idx.entities, result.record_count, result.head);
        try saveProfile(journal, fresh);
        break :blk fresh;
    };
    const notes_section = blk: {
        if ((try readJournalOrNull(allocator, journal, NotesFile))) |notes| {
            const sep = if (notes.len > 0 and notes[notes.len - 1] != '\n') "\n" else "";
            break :blk try allocator.print("# notes\n{s}{s}", .{ notes, sep });
        }
        break :blk try allocator.dupe(u8, "# notes\n(no notes)");
    };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, profile);
    try out.appendSlice(allocator, notes_section);
    allocator.free(profile);
    allocator.free(notes_section);
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- status

pub const ArtifactState = enum { fresh, stale, corrupt, missing };

pub const Artifact = struct {
    /// Journal-relative name ("derived/index.zdi", "profile.md", ...).
    name: []const u8,
    state: ArtifactState,
    /// The head recorded in the artifact, when readable.
    head: ?[records.DigestLen]u8,
    /// Index-only: format version and journal record count (null when the
    /// index does not decode).
    version: ?u8,
    record_count: ?u64,
};

pub const StatusReport = struct {
    items: []Artifact,
    allocator: Allocator,

    /// Frees the item names and the items slice.
    pub fn deinit(self: StatusReport) void {
        for (self.items) |a| self.allocator.free(a.name);
        self.allocator.free(self.items);
    }
};

pub const StatusError = Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error;

/// One entry per stored artifact: the index, the profile, and each stored
/// digest, in that order (digests sorted by name). `result` is the current
/// verify result; an artifact whose stored head differs is stale.
pub fn artifactStatus(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    result: journal_mod.VerifyResult,
) StatusError!StatusReport {
    var items = std.ArrayList(Artifact).empty;
    errdefer {
        for (items.items) |a| allocator.free(a.name);
        allocator.free(items.items);
    }

    // Index: binary, so its head, version, and record count come from a
    // decode; anything that does not decode is corrupt.
    if (try readJournalOrNull(allocator, journal, IndexFile)) |bytes| {
        defer allocator.free(bytes);
        if (derived.decodeIndex(allocator, bytes)) |idx| {
            defer idx.deinit();
            try items.append(allocator, .{
                .name = try allocator.dupe(u8, IndexFile),
                .state = if (std.mem.eql(u8, &idx.head, &result.head)) .fresh else .stale,
                .head = idx.head,
                .version = derived.IndexVersion,
                .record_count = idx.record_count,
            });
        } else |_| {
            try items.append(allocator, .{
                .name = try allocator.dupe(u8, IndexFile),
                .state = .corrupt,
                .head = null,
                .version = null,
                .record_count = null,
            });
        }
    } else {
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, IndexFile),
            .state = .missing,
            .head = null,
            .version = null,
            .record_count = null,
        });
    }

    // Profile: a document without the version header is a pre-Phase 7
    // legacy profile; it is stale until the next persisting read migrates it.
    if (try readJournalOrNull(allocator, journal, ProfileFile)) |doc| {
        defer allocator.free(doc);
        const versioned = std.mem.startsWith(u8, doc, ProfileHeader);
        const fresh = versioned and try headLineMatches(allocator, doc, result.head);
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, ProfileFile),
            .state = if (fresh) .fresh else .stale,
            .head = headFromLine(doc),
            .version = null,
            .record_count = null,
        });
    } else {
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, ProfileFile),
            .state = .missing,
            .head = null,
            .version = null,
            .record_count = null,
        });
    }

    // Digests: one entry per stored period, sorted by name.
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);
    if (Io.Dir.openDir(journal.dir, journal.io, DigestsDir, .{ .iterate = true })) |dir| {
        defer Io.Dir.close(dir, journal.io);
        var iter = Io.Dir.iterate(dir);
        while (try iter.next(journal.io)) |entry| {
            if (entry.kind != .file) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, nameLessThan);
        for (names.items) |name| {
            const full = try allocator.print(DigestsDir ++ "/{s}", .{name});
            errdefer allocator.free(full);
            var head: ?[records.DigestLen]u8 = null;
            var state = ArtifactState.missing;
            if ((try readJournalOrNull(allocator, journal, full))) |doc| {
                defer allocator.free(doc);
                head = headFromLine(doc);
                state = if (try headLineMatches(allocator, doc, result.head)) .fresh else .stale;
            }
            // `full` is owned by the report from here on.
            try items.append(allocator, .{
                .name = full,
                .state = state,
                .head = head,
                .version = null,
                .record_count = null,
            });
        }
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    // Hand off the items (the top errdefer becomes a no-op once the list is
    // empty), then free the scratch and return; nothing fallible follows.
    const owned = try items.toOwnedSlice(allocator);
    errdefer {
        for (owned) |a| allocator.free(a.name);
        allocator.free(owned);
    }
    names.deinit(allocator);
    return StatusReport{ .items = owned, .allocator = allocator };
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The `head=<64-hex>` value of `doc`'s first line, when present.
fn headFromLine(doc: []const u8) ?[records.DigestLen]u8 {
    const line_end = std.mem.indexOfScalar(u8, doc, '\n') orelse doc.len;
    const first = doc[0..line_end];
    const at = std.mem.indexOf(u8, first, "head=") orelse return null;
    const hex = first[at + 5 ..];
    if (hex.len < 2 * records.DigestLen) return null;
    var out: [records.DigestLen]u8 = undefined;
    for (0..records.DigestLen) |i| {
        const hi = hexNibble(hex[i * 2]) orelse return null;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return null;
        out[i] = @as(u8, @intCast(hi)) << 4 | @as(u8, @intCast(lo));
    }
    return out;
}

fn hexNibble(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return @as(u8, 10) + (c - 'a');
    if (c >= 'A' and c <= 'F') return @as(u8, 10) + (c - 'A');
    return null;
}

// ---------------------------------------------------------------- rebuild

pub const RebuildError = PackError || Io.Dir.DeleteFileError || Io.Dir.OpenError || Io.Dir.Iterator.Error;

pub const RebuildCounts = struct {
    word_count: usize,
    entity_count: usize,
};

/// Forces a rebuild: migrates a legacy profile first (its text goes to
/// notes.md, never destroyed), deletes the index, profile, and all stored
/// digests, then rewrites the index and profile from the verified log.
/// Digests regenerate on demand. `notes.md` is never touched.
pub fn rebuild(
    allocator: Allocator,
    journal: *const journal_mod.Journal,
    visible: *const view.Visible,
    result: journal_mod.VerifyResult,
) RebuildError!RebuildCounts {
    try migrateLegacyProfile(allocator, journal);
    try deleteQuiet(journal, IndexFile);
    try deleteQuiet(journal, ProfileFile);
    try deleteStoredDigests(allocator, journal);

    const idx = try derived.buildIndex(allocator, visible, result.head, result.record_count);
    defer idx.deinit();
    const counts: RebuildCounts = .{ .word_count = idx.words.len, .entity_count = idx.entities.len };
    try saveIndex(allocator, journal, idx);
    const profile = try derived.renderProfile(allocator, visible, idx.entities, result.record_count, result.head);
    defer allocator.free(profile);
    try saveProfile(journal, profile);
    return counts;
}

fn deleteQuiet(journal: *const journal_mod.Journal, name: []const u8) Io.Dir.DeleteFileError!void {
    return Io.Dir.deleteFile(journal.dir, journal.io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| e,
    };
}

fn deleteStoredDigests(allocator: Allocator, journal: *const journal_mod.Journal) RebuildError!void {
    const dir = Io.Dir.openDir(journal.dir, journal.io, DigestsDir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer Io.Dir.close(dir, journal.io);
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);
    var iter = Io.Dir.iterate(dir);
    while (try iter.next(journal.io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (names.items) |name| {
        const full = try allocator.print(DigestsDir ++ "/{s}", .{name});
        defer allocator.free(full);
        try deleteQuiet(journal, full);
    }
    // The last fallible work is done; the success path frees the scratch
    // itself (the errdefer above is error-path only).
    names.deinit(allocator);
}

// ---------------------------------------------------------------- tests

const D0: i64 = 20454; // 2026-01-01

test "context pack: deterministic bytes for a date-scoped question" {
    const gpa = std.testing.allocator;
    // The pack needs a journal; the in-process gate (test/phase7.zig) covers
    // it end to end. Here: only the pure retrieval ordering via retrieve().
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]view.ViewEntry{
        .{ .seq = 0, .ts_ms = 1, .tz_offset_min = 0, .day = D0, .redacted = false, .edited = false, .text = "shipped the auth fix", .tags = &.{"work"} },
        .{ .seq = 1, .ts_ms = 2, .tz_offset_min = 0, .day = D0, .redacted = false, .edited = false, .text = "walked the dog", .tags = &.{} },
        .{ .seq = 2, .ts_ms = 3, .tz_offset_min = 0, .day = D0, .redacted = false, .edited = false, .text = "shipped the deploy", .tags = &.{} },
    };
    var tl = std.ArrayList([]const []const u8).empty;
    for (entries) |e| {
        const copy = try allocator.alloc([]const u8, e.tags.len);
        for (copy, e.tags) |*s, t| s.* = t;
        try tl.append(allocator, copy);
    }
    var eo = std.ArrayList(view.ViewEntry).empty;
    for (entries) |e| try eo.append(allocator, e);
    const eo_owned = try eo.toOwnedSlice(allocator);
    const tl_owned = try tl.toOwnedSlice(allocator);
    const vis = view.Visible{ .entries = eo_owned, .tag_lists = tl_owned, .allocator = allocator };
    const genesis = records.Header.GenesisHash;
    const idx = try derived.buildIndex(allocator, &vis, genesis, 3);
    defer idx.deinit();

    const range = view.DayRange{ .start = D0, .end = D0 + 1 };
    const matches = try retrieve(allocator, &vis, &idx, "what did I ship?", range, 3);
    defer allocator.free(matches);
    // "ship" is not a token (the index has "shipped"); "did"/"I"/"what" are
    // stopwords or short — no token matches, so no matches.
    try std.testing.expectEqual(@as(usize, 0), matches.len);

    const shipped = try retrieve(allocator, &vis, &idx, "shipped?", range, 3);
    defer allocator.free(shipped);
    try std.testing.expectEqual(@as(usize, 2), shipped.len);
    try std.testing.expectEqual(@as(u64, 0), shipped[0].seq);
    try std.testing.expectEqual(@as(u64, 2), shipped[1].seq);
}
