//! zephyr verify [--head] — the full integrity check, plus the checkpoint
//! anchor check (anchor-format section 6) and the OTS anchor checks
//! (spec/ots-anchor.md section 6.1) when anchors exist. `--head` appends
//! the journal's head hash (first twelve hex digits) to the verdict line.

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
    style: output.Style,
    err_file: File,
    out: File,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    rest: []const []const u8,
) errors.RunError!void {
    var show_head = false;
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--head")) {
            show_head = true;
        } else {
            return error.Usage;
        }
    }
    const journal = try cli_journal.openReadJournal(arena, io, style, err_file, environ_map, path, false);
    defer journal.close();
    const result = try journal.verify(arena);
    if (result.ok) {
        const mark = try style.okMark(arena);
        if (result.record_count == 0) {
            try output.printLine(out, io, try arena.print("{s}verified · journal is empty", .{mark}));
        } else {
            const head = if (show_head)
                try arena.print(" · head {s}", .{try style.dim(arena, try output.hex12Of(arena, &result.head))})
            else
                "";
            const redacted = if (result.redacted_count > 0)
                try arena.print(" · {d} redacted", .{result.redacted_count})
            else
                "";
            try output.printLine(out, io, try arena.print(
                "{s}verified · {d} {s}{s}{s}",
                .{ mark, result.record_count, output.countNoun(result.record_count, "record", "records"), head, redacted },
            ));
        }

        // The anchor check (anchor-format section 6) runs only on a journal
        // that passed verify; a failing latest anchor means the journal must
        // not be trusted.
        const outcome = try journal.checkAnchors(arena);
        if (outcome.failure) |failure| {
            const file = outcome.file_name orelse "anchor";
            try output.printLine(err_file, io, try arena.print(
                "{s}anchor {s}: {s}",
                .{ try style.errMark(arena), file, output.anchorFailureReason(failure) },
            ));
            return error.VerifyFailed;
        }
        if (outcome.ok) |check| {
            try output.printLine(out, io, try arena.print(
                "{s}anchor · checkpoint seq {d}",
                .{ try style.okMark(arena), check.artifact.checkpoint_seq },
            ));
        }

        // The OTS anchor check (spec/ots-anchor.md section 6.1) runs on a
        // journal that passed verify: every stored proof must still bind to
        // its segment's footer head, or the journal must not be trusted.
        const ots_results = try journal.checkOtsAnchors(arena);
        for (ots_results) |check| {
            if (!check.ok) {
                const reason = output.otsCheckFailureReason(check.failure.?);
                try output.printLine(err_file, io, try arena.print(
                    "{s}ots anchors/{s}: {s}",
                    .{ try style.errMark(arena), check.file_name, reason },
                ));
                return error.VerifyFailed;
            }
            try output.printLine(out, io, try arena.print(
                "{s}ots · {s} · {s}",
                .{
                    try style.okMark(arena),
                    try style.dim(arena, check.file_name),
                    try output.attestationSummary(arena, check.attestations),
                },
            ));
        }
    } else {
        try output.reportIssue(err_file, io, style, arena, result.issue.?);
        return error.VerifyFailed;
    }
}
