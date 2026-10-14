//! zephyr verify — the full integrity check, plus the checkpoint anchor
//! check (anchor-format section 6) and the OTS anchor checks
//! (spec/ots-anchor.md section 6.1) when anchors exist.

const std = @import("std");
const errors = @import("../errors.zig");
const output = @import("../output.zig");
const cli_journal = @import("../journal.zig");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub fn run(
    arena: Allocator,
    io: Io,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
) errors.RunError!void {
    const journal = try cli_journal.openReadJournal(arena, io, err_file, environ_map, path);
    defer journal.close();
    const result = try journal.verify(arena);
    if (result.ok) {
        const line = if (result.record_count == 0) "ok: journal is empty" else blk: {
            const head_hex = try output.hexOf(arena, &result.head);
            const redacted = if (result.redacted_count > 0)
                try arena.print(", {d} redacted", .{result.redacted_count})
            else
                "";
            break :blk try arena.print("ok: {d} record(s), head {s}{s}", .{ result.record_count, head_hex, redacted });
        };
        try output.printLine(out, io, line);

        // The anchor check (anchor-format section 6) runs only on a journal
        // that passed verify; a failing latest anchor means the journal must
        // not be trusted.
        const outcome = try journal.checkAnchors(arena);
        if (outcome.failure) |failure| {
            const file = outcome.file_name orelse "anchor";
            try output.printLine(err_file, io, try arena.print("FAIL: anchor {s}: {s}", .{ file, output.anchorFailureReason(failure) }));
            return error.VerifyFailed;
        }
        if (outcome.ok) |check| {
            const head_hex = try output.hexOf(arena, &check.artifact.head);
            try output.printLine(out, io, try arena.print("anchor: ok (checkpoint seq {d}, head {s})", .{
                check.artifact.checkpoint_seq,
                head_hex,
            }));
        }

        // The OTS anchor check (spec/ots-anchor.md section 6.1) runs on a
        // journal that passed verify: every stored proof must still bind to
        // its segment's footer head, or the journal must not be trusted.
        const ots_results = try journal.checkOtsAnchors(arena);
        for (ots_results) |check| {
            if (!check.ok) {
                const reason = output.otsCheckFailureReason(check.failure.?);
                try output.printLine(err_file, io, try arena.print("FAIL: ots anchors/{s}: {s}", .{ check.file_name, reason }));
                return error.VerifyFailed;
            }
            try output.printLine(out, io, try arena.print("ots: ok ({s}, {s})", .{
                check.file_name,
                try output.attestationSummary(arena, check.attestations),
            }));
        }
    } else {
        try output.reportIssue(err_file, io, arena, result.issue.?);
        return error.VerifyFailed;
    }
}
