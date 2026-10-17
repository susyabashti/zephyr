//! Phase 4 gate: the LLM export path.
//!
//!   - `private` content never reaches the rendered LLM view.
//!   - The exporter refuses to render a log that fails verify.
//!   - Tokens per entry beat the raw JSON baseline (target in
//!     docs/features.md).
//!
//! Cross-implementation byte identity of the view itself is the Phase 0
//! vector contract (spec/vectors/journals.json `expect.view`, checked by
//! test/vectors.zig and the independent test/reference.py).

const std = @import("std");
const core = @import("zephyr_core");

const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const records = core.records;
const segment = core.segment;
const view = core.view;
const exporter = core.exporter;

test "phase 4: private content never reaches the LLM view" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-phase4", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    const journal = try core.journal.Journal.open(allocator, io, &environ, path, true);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    // All in one UTC day, so the view is a single date block.
    const base = 1_767_225_600_000; // 2026-01-01T00:00:00Z
    const pub_tags = [_][]const u8{"work"};
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "public one", &pub_tags, base, 0, false);
    // The private entry carries unique text AND a unique tag: neither may
    // appear in the export.
    const priv_tags = [_][]const u8{"PRIVATE-TAG-9c1b"};
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "PRIVATE-MARKER-8f3a", &priv_tags, base + 600_000, 0, true);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "public two", &pub_tags, base + 1_200_000, 0, false);

    const rendered = try exporter.render(allocator, &journal, null);
    try std.testing.expect(!contains(rendered, "PRIVATE-MARKER-8f3a"));
    try std.testing.expect(!contains(rendered, "PRIVATE-TAG-9c1b"));
    try std.testing.expect(contains(rendered, "public one"));
    try std.testing.expect(contains(rendered, "public two"));
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "phase 4: exporter refuses a failing log" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = Dir.cwd();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const path = try allocator.print("{s}/.tmp-phase4b", .{cwd_path});
    const environ = std.process.Environ.Map.init(allocator);

    Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) return e;
    const journal = try core.journal.Journal.open(allocator, io, &environ, path, true);
    defer {
        journal.close();
        Dir.deleteTree(cwd, io, path) catch |e| if (e != error.FileNotFound) std.debug.panic("could not clean up: {s}", .{@errorName(e)});
    }

    const base = 1_767_225_600_000; // 2026-01-01T00:00:00Z
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "first", &.{}, base, 0, false);
    _ = try journal.appendRecord(std.heap.page_allocator, .entry, 0, "second", &.{}, base + 600_000, 0, false);

    // The clean journal renders.
    _ = try exporter.render(allocator, &journal, null);

    // Corrupt record 0's stored record_hash (the block's leading 32 bytes)
    // and the export must refuse without rendering.
    const name = "2026-01.zph";
    const pristine = try readSeg(allocator, io, path, name);
    defer allocator.free(pristine);
    try flipSeg(allocator, io, path, name, pristine, 30 + 3);
    _ = try std.testing.expectError(error.VerifyFailed, exporter.render(allocator, &journal, null));

    // Restored: renders again.
    try writeSeg(allocator, io, path, name, pristine);
    _ = try exporter.render(allocator, &journal, null);
}

test "phase 4: tokens per entry beat raw JSON" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Same entry profile as the Phase 3 storage measurement (20-char text,
    // one 3-char tag, UTC). Built in memory: the renderer is a pure
    // function of the record stream, so no journal I/O is involved.
    const n: u32 = 10_000;
    const base_ms: u64 = 1_704_067_200_000; // 2024-01-01T00:00:00Z
    const step_ms: u64 = 1_040_000;

    const headers = try allocator.alloc(records.Header, n);
    const payloads = try allocator.alloc([]const u8, n);
    var prev = records.Header.GenesisHash;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const text = try allocator.print("synthetic entry {d:0>6}", .{i});
        const tags = [_][]const u8{"gen"};
        var salt: [records.SaltLen]u8 = undefined;
        @memset(&salt, @as(u8, @intCast(i % 251)));
        const payload = records.Payload{ .salt = salt, .text = text, .tags = &tags };
        const pbytes = try allocator.alloc(u8, records.payloadSize(text, &tags));
        records.encodePayload(&payload, pbytes);
        var header = records.Header{
            .version = records.FormatVersion,
            .record_type = .entry,
            .seq = i,
            .timestamp_ms = base_ms + @as(u64, i) * step_ms,
            .tz_offset_min = 0,
            .flags = 0,
            .target_seq = 0,
            .commitment = records.computeCommitment(pbytes),
            .record_hash = undefined,
        };
        var prefix: [records.HeaderPrefixLen]u8 = undefined;
        header.prefixBytes(&prefix);
        header.record_hash = records.computeRecordHash(&prefix, &prev);
        headers[i] = header;
        payloads[i] = pbytes;
        prev = header.record_hash;
    }

    const rendered = try view.render(allocator, headers, payloads);

    // Raw JSON baseline: one object per line for the same entries, same
    // shape as the Phase 3 JSONL.
    var jsonl = std.ArrayList(u8).empty;
    defer jsonl.deinit(allocator);
    i = 0;
    while (i < n) : (i += 1) {
        var buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"ts_ms\":{d},\"tz\":0,\"private\":false,\"text\":\"synthetic entry {d:0>6}\",\"tags\":[\"gen\"]}}\n", .{ base_ms + @as(u64, i) * step_ms, i }) catch unreachable;
        try jsonl.appendSlice(allocator, line);
    }

    // Token estimate: ceil(bytes/4), the ~4-chars-per-token heuristic for
    // English text — deterministic and implementation-independent, applied
    // to both formats so the comparison is like-for-like.
    const view_tokens: u64 = (rendered.len + 3) / 4;
    const jsonl_tokens: u64 = (jsonl.items.len + 3) / 4;
    const ratio: f64 = @as(f64, @floatFromInt(view_tokens)) / @as(f64, @floatFromInt(jsonl_tokens));

    // The report is off by default: under `zig build test` the runner talks
    // to the build system on stdout, and any stderr a test emits is shown by
    // zig build (0.17) in a step-failure report, making a passing gate look
    // like a crash in CI logs. Enable with ZEPHYR_TEST_VERBOSE=1.
    if (verboseReportEnabled()) {
        std.debug.print("\nphase 4 llm-view gate\n", .{});
        std.debug.print("  entries:               {d}\n", .{n});
        std.debug.print("  llm view bytes:        {d}\n", .{rendered.len});
        std.debug.print("  llm view tokens/entry: {d:.2}\n", .{@as(f64, @floatFromInt(view_tokens)) / @as(f64, @floatFromInt(n))});
        std.debug.print("  JSONL bytes:           {d}\n", .{jsonl.items.len});
        std.debug.print("  JSONL tokens/entry:    {d:.2}\n", .{@as(f64, @floatFromInt(jsonl_tokens)) / @as(f64, @floatFromInt(n))});
        std.debug.print("  ratio (llm/JSONL):     {d:.2}\n", .{ratio});
    }

    // The gate: the LLM view beats raw JSON, and stays under the target
    // ceiling (docs/features.md).
    try std.testing.expect(view_tokens < jsonl_tokens);
    try std.testing.expect(view_tokens <= TargetViewTokensTotal);
}

/// Is ZEPHYR_TEST_VERBOSE set in the process environment? Note that
/// `Environ.Map.init` returns an *empty* map in 0.17, so the real
/// environment is read by building an `Environ` over the C environ, the
/// same way std.start's main entry point does.
fn verboseReportEnabled() bool {
    const c_environ = std.c.environ;
    var count: usize = 0;
    while (c_environ[count] != null) : (count += 1) {}
    const environ = std.process.Environ{ .block = .{ .slice = c_environ[0..count :null] } };
    return std.process.Environ.containsConstant(environ, "ZEPHYR_TEST_VERBOSE");
}

/// Regression ceiling for the 10k-entry measurement above
/// (docs/features.md):
/// 11.0 tokens/entry, ~2% above the 10.77 measured for this entry profile.
/// (Phase B's bare-seq entry prefix adds ~8 bytes per entry over the
/// pre-Phase-B 8.80.)
const TargetViewTokensTotal: u64 = 110_000;

fn readSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8) (Allocator.Error || Dir.OpenError || Dir.ReadFileAllocError)![]u8 {
    const d = try Dir.openDirAbsolute(io, dir_path, .{});
    defer Dir.close(d, io);
    return try Dir.readFileAlloc(d, io, name, allocator, .unlimited);
}

fn writeSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8, data: []const u8) (Allocator.Error || Dir.OpenError || segment.WriteError)!void {
    _ = allocator;
    const d = try Dir.openDirAbsolute(io, dir_path, .{});
    defer Dir.close(d, io);
    return segment.writeAtomic(d, io, name, data);
}

fn flipSeg(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8, pristine: []const u8, offset: usize) (Allocator.Error || Dir.OpenError || segment.WriteError)!void {
    var data = try allocator.dupe(u8, pristine);
    defer allocator.free(data);
    data[offset] ^= 0x01;
    return writeSeg(allocator, io, dir_path, name, data);
}
