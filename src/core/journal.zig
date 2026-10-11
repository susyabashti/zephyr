//! Journal: a directory of monthly segment files (spec sections 6-8).
//!
//! Appends are atomic whole-file rewrites (ephemeral file + rename), segments
//! roll over per UTC month, and the hash chain continues across segment
//! boundaries. `verify` implements the two-pass check of spec section 8; the
//! pure in-memory form (`verifyBytes`) backs the vector harness.
//!
//! Callers must verify before trusting or extending the journal
//! (verify-before-trust); the CLI enforces this for every command.

const std = @import("std");
const records = @import("records.zig");
const segment = @import("segment.zig");
const anchor = @import("anchor.zig");
const ots = @import("ots.zig");
const timezone = @import("timezone.zig");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const OpenError = error{
    JournalNotFound,
} || Allocator.Error || Dir.OpenError || Dir.CreateDirPathOpenError || timezone.LoadError ||
    std.process.CurrentPathError || Io.Cancelable || Io.UnexpectedError;

pub const Journal = struct {
    io: Io,
    allocator: Allocator,
    dir: Dir,
    path: []const u8,
    tz: *const timezone.Tz,

    /// Opens (or, when `create_if_missing`, creates) the journal directory.
    /// `allocator` must outlive the journal and everything derived from it.
    pub fn open(
        allocator: Allocator,
        io: Io,
        environ_map: *const std.process.Environ.Map,
        path: []const u8,
        create_if_missing: bool,
    ) OpenError!Journal {
        const dir = if (create_if_missing)
            try Dir.createDirPathOpen(Dir.cwd(), io, path, .{
                .open_options = .{ .iterate = true },
            })
        else
            try Dir.openDirAbsolute(io, path, .{ .iterate = true });
        const tz_file = try timezone.resolveTzFile(allocator, environ_map);
        const tz = try timezone.load(allocator, io, tz_file);
        return Journal{ .io = io, .allocator = allocator, .dir = dir, .path = path, .tz = tz };
    }

    pub fn close(self: *const Journal) void {
        Dir.close(self.dir, self.io);
    }

    /// Local tz offset in whole minutes for a record at `ts_ms`.
    pub fn tzOffsetMinutesAtMs(self: *const Journal, ts_ms: u64) (timezone.LoadError || error{TzOutOfRange})!i16 {
        const ms: i64 = if (ts_ms > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(ts_ms);
        const secs: i64 = @divFloor(ms, 1000);
        const minutes = try timezone.offsetMinutesAt(self.tz, secs);
        if (minutes < records.TzOffsetMin or minutes > records.TzOffsetMax) return error.TzOutOfRange;
        return @intCast(minutes);
    }

    /// Segment file names in chronological (lexicographic) order.
    pub fn listSegments(self: *const Journal, allocator: Allocator) (Allocator.Error || Dir.Iterator.Error)![]const []const u8 {
        var iter = Dir.iterate(self.dir);
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!isSegmentName(entry.name)) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, segmentNameLessThan);
        return names.toOwnedSlice(allocator);
    }

    /// Appends a record, rolling the segment when the UTC month differs.
    /// Returns the new record's seq. The journal is assumed to have passed
    /// verify (the CLI enforces verify-before-trust).
    pub const AppendError = Allocator.Error || records.ValidateError || segment.WriteError ||
        segment.SummaryError || Dir.ReadFileAllocError || Dir.Iterator.Error || error{
        SegmentSealed,
        TzOutOfRange,
        EntropyUnavailable,
        PayloadRegionTooLarge,
    };

    pub fn appendRecord(
        self: *const Journal,
        allocator: Allocator,
        record_type: records.RecordType,
        target_seq: u64,
        text: []const u8,
        tags: []const []const u8,
        timestamp_ms: u64,
        tz_offset_min: i16,
        is_private: bool,
    ) AppendError!u64 {
        const names = try self.listSegments(allocator);
        defer allocator.free(names);
        const target_name = try segmentMonthName(allocator, timestamp_ms);
        defer allocator.free(target_name);

        // Chain state: seq is dense from 0, so the next seq is the total count.
        var files_before_count: u64 = 0;
        var files_before_head = records.Header.GenesisHash;
        var extend: ?segment.Summary = null;
        var seen_target = false;
        for (names) |name| {
            if (seen_target) continue;
            const bytes = try self.readFileBytes(allocator, name);
            defer allocator.free(bytes);
            const summary = try segment.summary(bytes);
            if (std.mem.eql(u8, name, target_name)) {
                seen_target = true;
                if (summary.sealed) return error.SegmentSealed;
                extend = summary;
            } else {
                files_before_count += summary.record_count;
                files_before_head = summary.head;
            }
        }

        const next_seq = files_before_count + if (extend) |e| e.record_count else 0;
        const prev_hash = if (extend) |e| e.head else files_before_head;

        // Build the record.
        var salt: [records.SaltLen]u8 = undefined;
        try Io.randomSecure(self.io, &salt);
        const payload = records.Payload{ .salt = salt, .text = text, .tags = tags };
        var header = records.Header{
            .version = records.FormatVersion,
            .record_type = record_type,
            .seq = next_seq,
            .timestamp_ms = timestamp_ms,
            .tz_offset_min = tz_offset_min,
            .flags = if (is_private) records.FlagPrivate else 0,
            .target_seq = target_seq,
            .commitment = undefined,
            .record_hash = undefined,
        };
        try records.validate(&header, &payload);
        const payload_bytes = try allocator.alloc(u8, records.payloadSize(text, tags));
        records.encodePayload(&payload, payload_bytes);
        header.commitment = records.computeCommitment(payload_bytes);
        var prefix: [records.HeaderPrefixLen]u8 = undefined;
        header.prefixBytes(&prefix);
        header.record_hash = records.computeRecordHash(&prefix, &prev_hash);
        var header_bytes: [records.HeaderLen]u8 = undefined;
        records.encodeHeader(&header, &header_bytes);
        const raw = segment.RawRecord{
            .record_hash = header.record_hash,
            .header = header_bytes,
            .payload = payload_bytes,
        };

        if (extend) |_| {
            const old = try self.readFileBytes(allocator, target_name);
            defer allocator.free(old);
            const new_bytes = try extendSegmentBytes(allocator, old, &raw);
            try segment.writeAtomic(self.dir, self.io, target_name, new_bytes);
        } else {
            // New segment: first seal the immediately preceding active one.
            if (names.len > 0) {
                const last = names[names.len - 1];
                if (!std.mem.eql(u8, last, target_name)) {
                    const bytes = try self.readFileBytes(allocator, last);
                    defer allocator.free(bytes);
                    const summary = try segment.summary(bytes);
                    if (!summary.sealed) {
                        const sealed_bytes = try sealSegmentBytes(allocator, bytes, &summary);
                        try segment.writeAtomic(self.dir, self.io, last, sealed_bytes);
                    }
                }
            }
            const file_header = segment.FileHeader{
                .version = records.FormatVersion,
                .sealed = false,
                .segment_start_seq = files_before_count,
                .record_count = 1,
                .header_region_len = records.RecordBlockLen,
                .payload_region_len = @intCast(4 + raw.payload.len),
            };
            const new_bytes = try segment.renderFile(allocator, &file_header, &.{raw});
            try segment.writeAtomic(self.dir, self.io, target_name, new_bytes);
        }
        return next_seq;
    }

    /// All records of the journal in order. The payloads borrow from the raw
    /// segment bytes in `files`, so call `deinit` to release everything.
    pub const RecordSet = struct {
        headers: []const records.Header,
        payloads: []const []const u8,
        /// Raw segment file bytes, in chronological order.
        files: [][]const u8,
        allocator: Allocator,

        pub fn deinit(self: RecordSet) void {
            const allocator = self.allocator;
            for (self.files) |bytes| allocator.free(bytes);
            allocator.free(self.files);
            allocator.free(self.payloads);
            allocator.free(self.headers);
        }
    };

    pub const CollectRecordsError = Allocator.Error || Dir.ReadFileAllocError || Dir.Iterator.Error ||
        segment.ParseError;

    pub fn collectRecords(self: *const Journal, allocator: Allocator) CollectRecordsError!RecordSet {
        const names = try self.listSegments(allocator);
        defer allocator.free(names);
        var headers = std.ArrayList(records.Header).empty;
        errdefer headers.deinit(allocator);
        var payloads = std.ArrayList([]const u8).empty;
        errdefer payloads.deinit(allocator);
        var files = std.ArrayList([]const u8).empty;
        errdefer files.deinit(allocator);
        for (names) |name| {
            // The file bytes must outlive the loop: the payload slices parsed
            // out of them are kept in `payloads`.
            const bytes = try self.readFileBytes(allocator, name);
            try files.append(allocator, bytes);
            var fail_index: usize = std.math.maxInt(usize);
            var seg = try segment.parse(allocator, name, bytes, &fail_index);
            for (seg.records) |h| try headers.append(allocator, h);
            for (seg.payloads) |p| try payloads.append(allocator, p);
            seg.deinit(allocator);
        }
        const owned_headers = try headers.toOwnedSlice(allocator);
        errdefer allocator.free(owned_headers);
        const owned_payloads = try payloads.toOwnedSlice(allocator);
        errdefer allocator.free(owned_payloads);
        const owned_files = try files.toOwnedSlice(allocator);
        errdefer allocator.free(owned_files);
        return RecordSet{
            .headers = owned_headers,
            .payloads = owned_payloads,
            .files = owned_files,
            .allocator = allocator,
        };
    }

    /// Redacts an entry: replaces the stored payload of the target entry and
    /// of every amendment on it with the 35-byte placeholder (payload region
    /// only; the headers and hash chain are untouched, spec sections 4 and
    /// 6), then appends the redaction record. Returns the redaction record's
    /// seq. The journal is assumed to have passed verify.
    pub const RedactError = Allocator.Error || Dir.ReadFileAllocError || Dir.Iterator.Error ||
        segment.ParseError || segment.RedactPayloadsError || AppendError || error{
        TargetNotFound,
        TargetNotEntry,
        AlreadyRedacted,
    };

    pub fn redact(
        self: *const Journal,
        allocator: Allocator,
        target_seq: u64,
        timestamp_ms: u64,
        tz_offset_min: i16,
    ) RedactError!u64 {
        const names = try self.listSegments(allocator);
        defer allocator.free(names);

        var found = false;
        for (names) |name| {
            const bytes = try self.readFileBytes(allocator, name);
            defer allocator.free(bytes);
            var fail_index: usize = std.math.maxInt(usize);
            var seg = try segment.parse(allocator, name, bytes, &fail_index);
            defer seg.deinit(allocator);

            var indexes = std.ArrayList(usize).empty;
            errdefer indexes.deinit(allocator);
            for (seg.records, 0..) |h, i| {
                if (h.seq == target_seq) {
                    if (h.record_type != .entry) return error.TargetNotEntry;
                    if (records.isRedactedPlaceholder(seg.payloads[i])) return error.AlreadyRedacted;
                    try indexes.append(allocator, i);
                } else if (h.record_type == .amendment and h.target_seq == target_seq) {
                    try indexes.append(allocator, i);
                }
            }
            if (indexes.items.len == 0) continue;
            found = true;
            const new_bytes = try segment.redactPayloads(allocator, bytes, indexes.items);
            try segment.writeAtomic(self.dir, self.io, name, new_bytes);
        }
        if (!found) return error.TargetNotFound;

        return try self.appendRecord(allocator, .redaction, target_seq, "", &.{}, timestamp_ms, tz_offset_min, false);
    }

    /// Names the entry that an amendment or tombstone may target.
    pub const ResolveTargetError = error{
        TargetNotFound,
        TargetNotEntry,
    };

    pub fn resolveEditTarget(headers: []const records.Header, seq: u64) ResolveTargetError!*const records.Header {
        if (seq >= headers.len) return error.TargetNotFound;
        if (headers[seq].record_type != .entry) return error.TargetNotEntry;
        return &headers[seq];
    }

    /// Full integrity check (spec section 8). Never frees caller-visible
    /// strings: pass an arena allocator and keep it alive past the result.
    pub const VerifyError = Allocator.Error || Dir.ReadFileAllocError || Dir.Iterator.Error ||
        segment.ParseError || records.DecodePayloadError;

    pub fn verify(self: *const Journal, allocator: Allocator) VerifyError!VerifyResult {
        const names = try self.listSegments(allocator);
        var files = std.ArrayList(verifyFile).empty;
        errdefer files.deinit(allocator);
        for (names) |name| {
            const bytes = try self.readFileBytes(allocator, name);
            try files.append(allocator, .{ .name = name, .bytes = bytes });
        }
        return verifyBytes(allocator, files.items);
    }

    /// The journal's latest anchor (anchor-format section 6).
    pub const AnchorCheck = struct {
        artifact: anchor.Artifact,
        file_name: []const u8,
    };

    /// The latest artifact's self-verification or chain-linkage failure. When
    /// set, the journal must not be trusted.
    pub const CheckAnchorsFailure = anchor.VerifyError || anchor.ChainError;

    pub const AnchorCheckResult = struct {
        /// `null` when the journal has no anchors (check skipped) or when the
        /// latest anchor failed.
        ok: ?AnchorCheck,
        /// The latest artifact's file name, when one was found.
        file_name: ?[]const u8,
        /// The anchor failure, if any.
        failure: ?CheckAnchorsFailure,
    };

    pub const CheckAnchorsError = Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError ||
        Dir.Iterator.Error || CollectRecordsError;

    /// Runs the anchor check (anchor-format section 6): load the latest
    /// artifact from `<journal>/anchors/`, verify it, and check chain
    /// linkage against the journal's records. Returns a null result when no
    /// anchors exist. I/O failures propagate; anchor verification failures
    /// are reported in the result, not as errors.
    pub fn checkAnchors(self: *const Journal, allocator: Allocator) CheckAnchorsError!AnchorCheckResult {
        const none = AnchorCheckResult{ .ok = null, .file_name = null, .failure = null };
        const anchors_dir = Dir.openDir(self.dir, self.io, "anchors", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return none,
            else => return err,
        };
        defer Dir.close(anchors_dir, self.io);

        var names = std.ArrayList([]const u8).empty;
        errdefer names.deinit(allocator);
        var iter = Dir.iterate(anchors_dir);
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zpa")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        if (names.items.len == 0) return none;

        // The latest artifact is the one with the highest checkpoint_seq.
        // The field is read raw so a malformed artifact still identifies as
        // the latest (and is then reported as the failing one).
        var best_name: ?[]const u8 = null;
        var best_seq: u64 = 0;
        for (names.items) |name| {
            const bytes = try Dir.readFileAlloc(anchors_dir, self.io, name, allocator, .unlimited);
            defer allocator.free(bytes);
            if (bytes.len != anchor.ArtifactLen) continue;
            const seq = records.readU64(bytes[86..94]);
            if (best_name == null or seq > best_seq) {
                best_name = name;
                best_seq = seq;
            }
        }
        const name = best_name orelse return none;

        const bytes = try Dir.readFileAlloc(anchors_dir, self.io, name, allocator, .unlimited);
        defer allocator.free(bytes);
        const artifact = anchor.verifyBytes(bytes) catch |err| {
            return .{ .ok = null, .file_name = name, .failure = err };
        };

        const recs = try self.collectRecords(allocator);
        defer recs.deinit();
        anchor.checkChain(&artifact, recs.headers) catch |err| {
            return .{ .ok = null, .file_name = name, .failure = err };
        };
        return .{ .ok = .{ .artifact = artifact, .file_name = name }, .file_name = name, .failure = null };
    }

    /// Writes an anchor artifact to `<journal>/anchors/checkpoint-<seq>.zpa`
    /// (anchor-format section 5); the anchors directory is created if needed.
    pub const WriteAnchorError = Allocator.Error || Dir.CreateDirPathError || segment.WriteError;

    pub fn writeAnchorFile(self: *const Journal, allocator: Allocator, checkpoint_seq: u64, bytes: []const u8) WriteAnchorError!void {
        try Dir.createDirPath(self.dir, self.io, "anchors");
        const name = try allocator.print("anchors/checkpoint-{d}.zpa", .{checkpoint_seq});
        try segment.writeAtomic(self.dir, self.io, name, bytes);
    }

    /// Writes an OTS proof to `<journal>/anchors/ots-<YYYY-MM>.ots` (spec/ots-
    /// anchor.md section 5); the anchors directory is created if needed.
    pub fn writeOtsAnchorFile(self: *const Journal, allocator: Allocator, month: []const u8, bytes: []const u8) WriteAnchorError!void {
        try Dir.createDirPath(self.dir, self.io, "anchors");
        const name = try allocator.print("anchors/ots-{s}.ots", .{month});
        try segment.writeAtomic(self.dir, self.io, name, bytes);
    }

    /// The raw bytes of a segment file (spec/ots-anchor.md section 7).
    pub fn readSegment(self: *const Journal, allocator: Allocator, name: []const u8) Dir.ReadFileAllocError![]u8 {
        return try Dir.readFileAlloc(self.dir, self.io, name, allocator, .unlimited);
    }

    /// The raw bytes of a file in the journal directory (spec/mcp.md: the
    /// profile document). error.FileNotFound when it does not exist.
    pub fn readJournalFile(self: *const Journal, allocator: Allocator, name: []const u8) Dir.ReadFileAllocError![]u8 {
        return try Dir.readFileAlloc(self.dir, self.io, name, allocator, .unlimited);
    }

    /// Every OTS anchor in `<journal>/anchors/` (spec/ots-anchor.md section 5):
    /// files named `ots-<YYYY-MM>.ots` with a valid month. Each anchor is
    /// checked against the referenced segment's footer head; anchor failures
    /// are reported in the results (not as errors) and I/O failures
    /// propagate. The result, including the pending URIs in the
    /// attestations, is owned by `allocator`.
    pub const OtsCheckFailure = ots.VerifyError || error{
        SegmentMissing,
        SegmentNotSealed,
    };

    pub const OtsAnchorCheck = struct {
        /// The anchor's file name (without the `anchors/` prefix).
        file_name: []const u8,
        /// The referenced segment's file name.
        segment_name: []const u8,
        ok: bool,
        failure: ?OtsCheckFailure,
        /// Valid when `ok`.
        attestations: []const ots.AttestationHit,
    };

    pub const CheckOtsAnchorsError = Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError ||
        Dir.Iterator.Error || segment.FooterHeadError;

    pub fn checkOtsAnchors(self: *const Journal, allocator: Allocator) CheckOtsAnchorsError![]OtsAnchorCheck {
        const anchors_dir = Dir.openDir(self.dir, self.io, "anchors", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => return err,
        };
        defer Dir.close(anchors_dir, self.io);

        var names = std.ArrayList([]const u8).empty;
        errdefer names.deinit(allocator);
        var iter = Dir.iterate(anchors_dir);
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!isOtsAnchorName(entry.name)) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        if (names.items.len == 0) return &.{};
        std.mem.sort([]const u8, names.items, {}, segmentNameLessThan);

        var results = std.ArrayList(OtsAnchorCheck).empty;
        errdefer results.deinit(allocator);
        for (names.items) |name| {
            const segment_name = try allocator.print("{s}.zph", .{name[4..11]});
            var check = OtsAnchorCheck{
                .file_name = name,
                .segment_name = segment_name,
                .ok = false,
                .failure = null,
                .attestations = &.{},
            };
            const proof = try Dir.readFileAlloc(anchors_dir, self.io, name, allocator, .unlimited);
            const seg_bytes = Dir.readFileAlloc(self.dir, self.io, segment_name, allocator, .unlimited) catch |err| {
                allocator.free(proof);
                check.failure = if (err == error.FileNotFound) error.SegmentMissing else return err;
                try results.append(allocator, check);
                continue;
            };
            const head = segment.footerHead(seg_bytes) catch |err| {
                allocator.free(seg_bytes);
                allocator.free(proof);
                check.failure = if (err == error.NotSealed) error.SegmentNotSealed else return err;
                try results.append(allocator, check);
                continue;
            };
            var expected: [32]u8 = undefined;
            records.Sha256.hash(&head, &expected, .{});
            const verification = ots.verify(allocator, proof, &expected) catch |err| {
                allocator.free(seg_bytes);
                allocator.free(proof);
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |e| check.failure = e,
                }
                try results.append(allocator, check);
                continue;
            };
            allocator.free(seg_bytes);
            allocator.free(proof);
            check.ok = true;
            check.attestations = verification.attestations;
            try results.append(allocator, check);
        }
        return try results.toOwnedSlice(allocator);
    }

    fn readFileBytes(self: *const Journal, allocator: Allocator, name: []const u8) Dir.ReadFileAllocError![]u8 {
        return try Dir.readFileAlloc(self.dir, self.io, name, allocator, .unlimited);
    }
};

pub const verifyFile = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const VerifyIssue = struct {
    file: []const u8,
    seq: u64,
    field: []const u8,
    detail: []const u8,
};

pub const VerifyResult = struct {
    ok: bool,
    record_count: u64,
    redacted_count: u64,
    head: [records.DigestLen]u8,
    issue: ?VerifyIssue,
};

/// The pure two-pass verify over in-memory files (spec section 8). Files must
/// be in chronological (name) order. Never frees its inputs.
pub const VerifyBytesError = Allocator.Error || segment.ParseError || records.DecodePayloadError;

pub fn verifyBytes(allocator: Allocator, files: []const verifyFile) VerifyBytesError!VerifyResult {
    if (files.len == 0) {
        return VerifyResult{
            .ok = true,
            .record_count = 0,
            .redacted_count = 0,
            .head = records.Header.GenesisHash,
            .issue = null,
        };
    }

    var segments = std.ArrayList(segment.Segment).empty;
    errdefer segments.deinit(allocator);
    var parsed_before: u64 = 0;
    for (files) |f| {
        var fail_index: usize = std.math.maxInt(usize);
        const seg = segment.parse(allocator, f.name, f.bytes, &fail_index) catch |err| {
            const seq = if (fail_index != std.math.maxInt(usize)) parsed_before + @as(u64, fail_index) else 0;
            return VerifyResult{
                .ok = false,
                .record_count = 0,
                .redacted_count = 0,
                .head = records.Header.GenesisHash,
                .issue = parseIssue(allocator, f.name, err, seq),
            };
        };
        parsed_before += seg.recordCount();
        try segments.append(allocator, seg);
    }

    var total: u64 = 0;
    for (segments.items) |seg| total += seg.recordCount();

    const types = try allocator.alloc(records.RecordType, total);
    const targets = try allocator.alloc(u64, total);
    const is_entry = try allocator.alloc(bool, total);
    const file_of = try allocator.alloc(usize, total);
    const redacted = try allocator.alloc(bool, total);
    @memset(redacted, false);

    // Pass 1: chain and seq continuity (spec section 8, pass 1).
    var prev = records.Header.GenesisHash;
    var expected_seq: u64 = 0;
    var idx: u64 = 0;
    for (segments.items, 0..) |seg, s| {
        for (seg.records) |h| {
            types[idx] = h.record_type;
            targets[idx] = h.target_seq;
            is_entry[idx] = h.record_type == .entry;
            file_of[idx] = s;

            var prefix: [records.HeaderPrefixLen]u8 = undefined;
            h.prefixBytes(&prefix);
            const recomputed = records.computeRecordHash(&prefix, &prev);
            if (!std.mem.eql(u8, &recomputed, &h.record_hash)) {
                return fail(allocator, seg.file_name, h.seq, "record_hash", "chain mismatch");
            }
            if (h.seq != expected_seq) {
                return fail(allocator, seg.file_name, h.seq, "seq", try seqDetail(allocator, expected_seq));
            }
            prev = h.record_hash;
            expected_seq += 1;
            idx += 1;
        }
    }

    // Pass 2a: redaction set (spec section 8, pass 2, step 5).
    for (0..total) |i| {
        if (types[i] != .redaction) continue;
        const t = targets[i];
        if (t >= total) {
            return fail(allocator, files[file_of[i]].name, i, "target_seq", "redaction target not found");
        }
        if (redacted[t]) {
            return fail(allocator, files[file_of[i]].name, t, "redaction", "duplicate redaction of entry");
        }
        redacted[t] = true;
    }

    // Pass 2b: payloads — commitment or redacted placeholder (step 6).
    var redacted_count: u64 = 0;
    var gi: u64 = 0;
    for (segments.items) |seg| {
        for (seg.records, seg.payloads, 0..) |h, payload, i| {
            const decoded = records.decodePayload(allocator, payload) catch |err| {
                return fail(allocator, seg.file_name, h.seq, "payload", payloadDecodeDetail(err));
            };
            allocator.free(decoded.tags); // verify only needs the structure check
            // A redaction applies to the target entry and every amendment on
            // it (spec section 3.1), so both carry the placeholder payload.
            const target_redacted = h.target_seq < total and redacted[h.target_seq];
            const is_redacted_record = (h.record_type == .entry and redacted[h.seq]) or
                (h.record_type == .amendment and target_redacted);
            if (is_redacted_record) {
                if (!records.isRedactedPlaceholder(payload)) {
                    return fail(allocator, seg.file_name, h.seq, "payload", "redacted record does not carry the placeholder payload");
                }
                if (h.record_type == .entry) redacted_count += 1;
            } else {
                const commitment = records.computeCommitment(payload);
                if (!std.mem.eql(u8, &commitment, &h.commitment)) {
                    return fail(allocator, seg.file_name, h.seq, "commitment", "payload does not match commitment");
                }
            }
            gi += 1;
            _ = i;
        }
    }

    // Pass 2c: target validity (step 7).
    for (0..total) |i| {
        switch (types[i]) {
            .entry, .checkpoint => {},
            else => {
                const t = targets[i];
                if (t >= total) {
                    return fail(allocator, files[file_of[i]].name, i, "target_seq", "target not found");
                }
                if (t >= @as(u64, i)) {
                    return fail(allocator, files[file_of[i]].name, i, "target_seq", "target is not earlier than the record");
                }
                if (!is_entry[t]) {
                    return fail(allocator, files[file_of[i]].name, i, "target_seq", "target is not an entry");
                }
            },
        }
    }

    // Pass 2d: sealed footers (step 8).
    for (segments.items) |seg| {
        if (seg.footer) |f| {
            const start = seg.header.segment_start_seq;
            const count = seg.recordCount();
            if (f.first_seq != start or f.count != count or f.last_seq != start + count - 1) {
                return fail(allocator, seg.file_name, f.first_seq, "footer", "footer fields do not match the segment");
            }
            if (!std.mem.eql(u8, &f.head, &seg.records[seg.records.len - 1].record_hash)) {
                return fail(allocator, seg.file_name, f.last_seq, "footer", "footer head does not match the final record_hash");
            }
            const expected_hash = segment.computeFooterHash(f.first_seq, f.last_seq, f.count, &f.head);
            if (!std.mem.eql(u8, &expected_hash, &f.hash)) {
                return fail(allocator, seg.file_name, f.first_seq, "footer", "footer hash mismatch");
            }
        }
    }

    const last_seg = segments.items[segments.items.len - 1];
    return VerifyResult{
        .ok = true,
        .record_count = total,
        .redacted_count = redacted_count,
        .head = last_seg.head(),
        .issue = null,
    };
}

fn fail(allocator: Allocator, file: []const u8, seq: u64, field: []const u8, detail: []const u8) VerifyResult {
    const dup_file = allocator.dupe(u8, file) catch unreachable;
    const dup_detail = allocator.dupe(u8, detail) catch unreachable;
    return VerifyResult{
        .ok = false,
        .record_count = 0,
        .redacted_count = 0,
        .head = records.Header.GenesisHash,
        .issue = .{ .file = dup_file, .seq = seq, .field = field, .detail = dup_detail },
    };
}

fn seqDetail(allocator: Allocator, expected: u64) Allocator.Error![]const u8 {
    return try allocator.print("expected seq {d}", .{expected});
}

fn parseIssue(allocator: Allocator, file: []const u8, err: segment.ParseError, seq: u64) ?VerifyIssue {
    const pair: [2][]const u8 = switch (err) {
        error.FileTooShort => .{ "file", "file is truncated" },
        error.BadMagic => .{ "magic", "bad magic" },
        error.BadVersion => .{ "version", "unsupported version" },
        error.ReservedFlagBit => .{ "flags", "reserved flag bit set" },
        error.EmptySegment => .{ "record_count", "segment has no records" },
        error.BadHeaderRegionLen => .{ "header_region_len", "header region length inconsistent" },
        error.SizeMismatch => .{ "file", "file size inconsistent with header" },
        error.TruncatedPayloadRegion => .{ "payload_region", "payload region truncated" },
        error.StoredHashMismatch => .{ "record_hash", "stored record_hash copy differs from header" },
        error.TzOutOfRange => .{ "tz_offset_min", "tz offset out of range" },
        else => .{ "header", "record header invalid" },
    };
    return fail(allocator, file, seq, pair[0], pair[1]).issue;
}

fn payloadDecodeDetail(err: records.DecodePayloadError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.Truncated => "payload truncated",
        error.BadTagLength => "tag with zero length",
        error.DuplicateTag => "duplicate tag",
        error.BadUtf8 => "payload is not valid UTF-8",
        error.ControlCharacter => "payload contains a control character",
        error.CombiningMark => "payload contains a combining mark",
    };
}

/// Extends an unsealed segment file with one record. The new block is
/// inserted at the end of the header region (spec section 6 keeps all
/// blocks together); the new payload goes to the end of the file.
/// `old` must be a complete, size-consistent unsealed file.
pub fn extendSegmentBytes(allocator: Allocator, old: []const u8, raw: *const segment.RawRecord) Allocator.Error![]u8 {
    const count = records.readU64(old[14..22]);
    const block_start = segment.FileHeaderLen + @as(usize, count) * records.RecordBlockLen;
    const out = try allocator.alloc(u8, old.len + records.RecordBlockLen + 4 + raw.payload.len);
    // File header + existing blocks, then the new block.
    @memcpy(out[0..block_start], old[0..block_start]);
    @memcpy(out[block_start .. block_start + records.DigestLen], &raw.record_hash);
    @memcpy(out[block_start + records.DigestLen .. block_start + records.RecordBlockLen], &raw.header);
    // Existing payloads, shifted past the new block.
    @memcpy(out[block_start + records.RecordBlockLen .. old.len + records.RecordBlockLen], old[block_start..]);
    // New payload at the end of the file.
    const payload_start = old.len + records.RecordBlockLen;
    records.putU32(out[payload_start .. payload_start + 4], @intCast(raw.payload.len));
    @memcpy(out[payload_start + 4 ..], raw.payload);
    // Patch the file header counters.
    records.putU64(out[14..22], count + 1);
    records.putU32(out[22..26], @intCast(records.readU32(out[22..26]) + records.RecordBlockLen));
    records.putU32(out[26..30], @intCast(records.readU32(out[26..30]) + 4 + raw.payload.len));
    return out;
}

fn sealSegmentBytes(allocator: Allocator, bytes: []const u8, summary: *const segment.Summary) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, bytes.len + segment.FooterLen);
    @memcpy(out[0..bytes.len], bytes);
    out[5] |= segment.FlagSealed;
    const file_header = segment.FileHeader{
        .version = records.FormatVersion,
        .sealed = true,
        .segment_start_seq = summary.start_seq,
        .record_count = summary.record_count,
        .header_region_len = 0,
        .payload_region_len = 0,
    };
    segment.writeFooter(out[bytes.len..][0..segment.FooterLen], &file_header, &summary.head);
    return out;
}

/// `<YYYY>-<MM>.zph` for the UTC month containing `ts_ms` (spec section 6).
fn segmentMonthName(allocator: Allocator, ts_ms: u64) Allocator.Error![]const u8 {
    const secs: u64 = ts_ms / 1000;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return allocator.print("{d:0>4}-{d:0>2}.zph", .{ year_day.year, month_day.month.numeric() });
}

/// Whether `name` is a well-formed segment file name `<YYYY>-<MM>.zph`.
pub fn isSegmentName(name: []const u8) bool {
    if (name.len != 11) return false;
    if (name[4] != '-' or name[7] != '.') return false;
    if (!std.mem.eql(u8, name[8..11], "zph")) return false;
    for (name[0..4]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    for (name[5..7]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    const month = std.fmt.parseInt(u32, name[5..7], 10) catch return false;
    return month >= 1 and month <= 12;
}

/// Whether `name` is a well-formed OTS anchor name `ots-<YYYY-MM>.ots`
/// (spec/ots-anchor.md section 5).
fn isOtsAnchorName(name: []const u8) bool {
    if (name.len != 15) return false;
    if (!std.mem.startsWith(u8, name, "ots-")) return false;
    if (!std.mem.endsWith(u8, name, ".ots")) return false;
    var full: [11]u8 = undefined;
    @memcpy(full[0..7], name[4..11]);
    @memcpy(full[7..11], ".zph");
    return isSegmentName(&full);
}

fn segmentNameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn makeRawRecord(allocator: Allocator, seq: u64, prev_hash: [records.DigestLen]u8, text: []const u8) Allocator.Error!segment.RawRecord {
    var salt: [records.SaltLen]u8 = undefined;
    @memset(&salt, @as(u8, @intCast(seq)));
    const payload = records.Payload{ .salt = salt, .text = text, .tags = &.{} };
    var header = records.Header{
        .version = records.FormatVersion,
        .record_type = .entry,
        .seq = seq,
        .timestamp_ms = 1000 + seq,
        .tz_offset_min = 0,
        .flags = 0,
        .target_seq = 0,
        .commitment = undefined,
        .record_hash = undefined,
    };
    const payload_bytes = try allocator.alloc(u8, records.payloadSize(text, &.{}));
    records.encodePayload(&payload, payload_bytes);
    header.commitment = records.computeCommitment(payload_bytes);
    var prefix: [records.HeaderPrefixLen]u8 = undefined;
    header.prefixBytes(&prefix);
    header.record_hash = records.computeRecordHash(&prefix, &prev_hash);
    var header_bytes: [records.HeaderLen]u8 = undefined;
    records.encodeHeader(&header, &header_bytes);
    return segment.RawRecord{ .record_hash = header.record_hash, .header = header_bytes, .payload = payload_bytes };
}

test "extendSegmentBytes inserts the block in the header region" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rec0 = try makeRawRecord(allocator, 0, records.Header.GenesisHash, "first entry");
    const file0 = try segment.renderFile(allocator, &.{
        .version = records.FormatVersion,
        .sealed = false,
        .segment_start_seq = 0,
        .record_count = 1,
        .header_region_len = records.RecordBlockLen,
        .payload_region_len = @intCast(4 + rec0.payload.len),
    }, &.{rec0});

    const rec1 = try makeRawRecord(allocator, 1, rec0.record_hash, "second entry");
    const file1 = try extendSegmentBytes(allocator, file0, &rec1);

    // The extended file must parse: the second block sits at the end of the
    // header region, with both payloads in the payload region (spec section 6).
    var fail_index: usize = std.math.maxInt(usize);
    var seg = try segment.parse(allocator, "2026-01.zph", file1, &fail_index);
    defer seg.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), seg.recordCount());
    try std.testing.expectEqual(@as(u64, 1), seg.records[1].seq);
    const decoded = try records.decodePayload(allocator, seg.payloads[1]);
    defer allocator.free(decoded.tags);
    try std.testing.expectEqualStrings("second entry", decoded.text);
    try std.testing.expectEqualSlices(u8, &rec1.record_hash, &seg.records[1].record_hash);

    // The whole file must pass the two-pass verify.
    const result = try verifyBytes(allocator, &.{.{ .name = "2026-01.zph", .bytes = file1 }});
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u64, 2), result.record_count);
}
