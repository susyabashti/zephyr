//! CLI: zephyr (editor)  |  zephyr <text>  |  zephyr log [-t TAG]... <text>
//!     |  zephyr verify
//!     zephyr today | yesterday | week | on YYYY-MM-DD  |  zephyr search <q>
//!     zephyr ask [from:to] <question...>  |  zephyr recap [start..end]
//!     zephyr profile  |  zephyr derived status|rebuild
//!     zephyr model fetch [--force] | zephyr model status  |  zephyr key status
//!     zephyr edit <seq> [-t TAG]... "text"  |  zephyr rm <seq>
//!     zephyr redact <seq> [--yes]  |  zephyr checkpoint [--key PATH]
//!     zephyr export --for-ai [YYYY-MM-DD[:YYYY-MM-DD]]
//!     zephyr ots-stamp <segment> --proof <path>  |  zephyr ots-export <segment> [--out <path]]
//!
//! Exit codes: 0 ok, 1 integrity or journal error, 2 usage error.
//!
//! Thin entry point: parses the global options, resolves the journal path,
//! and dispatches to commands/ (one module per command). The shared pieces
//! live in args.zig (parsing), errors.zig (the error set), journal.zig
//! (journal access), and output.zig (rendering).

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors.zig");
const cli_journal = @import("journal.zig");
const output = @import("output.zig");

const ask_cmd = @import("commands/ask.zig");
const checkpoint_cmd = @import("commands/checkpoint.zig");
const derived_cmd = @import("commands/derived.zig");
const edit_cmd = @import("commands/edit.zig");
const export_cmd = @import("commands/export.zig");
const log_cmd = @import("commands/log.zig");
const key_cmd = @import("commands/key.zig");
const mcp_cmd = @import("commands/mcp.zig");
const model_cmd = @import("commands/model.zig");
const ots_export_cmd = @import("commands/ots-export.zig");
const ots_stamp_cmd = @import("commands/ots-stamp.zig");
const profile_cmd = @import("commands/profile.zig");
const rank_cmd = @import("commands/rank.zig");
const recap_cmd = @import("commands/recap.zig");
const redact_cmd = @import("commands/redact.zig");
const rm_cmd = @import("commands/rm.zig");
const search_cmd = @import("commands/search.zig");
const verify_cmd = @import("commands/verify.zig");
const views_cmd = @import("commands/views.zig");

const Io = std.Io;
const File = Io.File;

pub const Version: []const u8 = "0.2.1";

pub const RunError = errors.RunError;

pub fn run(init: std.process.Init, argv: []const []const u8) RunError!void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const out = File.stdout();
    const err_file = File.stderr();
    // Style once, on the stream the user reads: color only on a TTY (and
    // unless $NO_COLOR is set), so piped output stays byte-stable.
    const style = output.Style.detect(out, io, init.environ_map);

    var journal_path: ?[]const u8 = null;
    var no_pager = false;
    var i: usize = 1;
    // Global options before the command.
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--journal")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            journal_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--no-pager")) {
            no_pager = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try output.printLine(out, io, "zephyr " ++ Version ++ " (format v1)");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            try output.printUsage(err_file, io);
            return;
        } else {
            break;
        }
    }
    if (i >= argv.len) {
        // `zephyr` with no command opens the editor for a new entry; log
        // decides editor-vs-usage (it owns the TTY check).
        const path = try cli_journal.resolveJournalPath(arena, io, init.environ_map, journal_path);
        return log_cmd.run(arena, gpa, io, style, init.environ_map, path, &.{});
    }
    const command = argv[i];

    // A bare word (not a known command) is a quick log; the word itself is
    // the first part of the text, so the text starts at `command`, not after
    // it.
    if (!isCommand(command)) {
        const path = try cli_journal.resolveJournalPath(arena, io, init.environ_map, journal_path);
        return log_cmd.run(arena, gpa, io, style, init.environ_map, path, argv[i..]);
    }

    const rest = argv[i + 1 ..];
    const path = try cli_journal.resolveJournalPath(arena, io, init.environ_map, journal_path);
    if (std.mem.eql(u8, command, "log")) {
        return log_cmd.run(arena, gpa, io, style, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "verify")) {
        return verify_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "today") or std.mem.eql(u8, command, "yesterday") or std.mem.eql(u8, command, "week")) {
        return views_cmd.runDayView(arena, io, style, err_file, out, init.environ_map, path, command, no_pager);
    } else if (std.mem.eql(u8, command, "on")) {
        if (rest.len != 1) return error.Usage;
        const day = args.parseCivilDate(rest[0]) orelse return error.Usage;
        return views_cmd.runRangeView(arena, io, style, err_file, out, init.environ_map, path, .{ .start = day, .end = day + 1 }, no_pager);
    } else if (std.mem.eql(u8, command, "export")) {
        return export_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "search")) {
        return search_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest, no_pager);
    } else if (std.mem.eql(u8, command, "ask")) {
        return ask_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest, no_pager);
    } else if (std.mem.eql(u8, command, "recap")) {
        return recap_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest, no_pager);
    } else if (std.mem.eql(u8, command, "profile")) {
        return profile_cmd.run(arena, io, style, err_file, out, init.environ_map, path, no_pager);
    } else if (std.mem.eql(u8, command, "derived")) {
        return derived_cmd.run(arena, gpa, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "model")) {
        return model_cmd.run(arena, gpa, io, style, err_file, out, init.environ_map, rest);
    } else if (std.mem.eql(u8, command, "key")) {
        return key_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "rank")) {
        return rank_cmd.run(arena, gpa, io, style, err_file, out, init.environ_map, path, rest, no_pager);
    } else if (std.mem.eql(u8, command, "edit")) {
        return edit_cmd.run(arena, gpa, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "rm")) {
        return rm_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "redact")) {
        return redact_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "checkpoint")) {
        return checkpoint_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "ots-stamp")) {
        return ots_stamp_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "ots-export")) {
        return ots_export_cmd.run(arena, io, style, err_file, out, init.environ_map, path, rest);
    } else if (std.mem.eql(u8, command, "mcp")) {
        // A machine protocol: no styling, ever.
        return mcp_cmd.run(arena, io, output.Style.off, err_file, init.environ_map, path, rest);
    } else {
        unreachable; // isCommand is the set of known commands
    }
}

fn isCommand(s: []const u8) bool {
    return std.mem.eql(u8, s, "log") or std.mem.eql(u8, s, "verify") or
        std.mem.eql(u8, s, "today") or std.mem.eql(u8, s, "yesterday") or
        std.mem.eql(u8, s, "week") or std.mem.eql(u8, s, "on") or
        std.mem.eql(u8, s, "search") or std.mem.eql(u8, s, "ask") or
        std.mem.eql(u8, s, "recap") or std.mem.eql(u8, s, "profile") or
        std.mem.eql(u8, s, "derived") or std.mem.eql(u8, s, "model") or
        std.mem.eql(u8, s, "key") or
        std.mem.eql(u8, s, "edit") or
        std.mem.eql(u8, s, "rm") or std.mem.eql(u8, s, "redact") or
        std.mem.eql(u8, s, "checkpoint") or std.mem.eql(u8, s, "export") or
        std.mem.eql(u8, s, "ots-stamp") or std.mem.eql(u8, s, "ots-export") or
        std.mem.eql(u8, s, "mcp") or std.mem.eql(u8, s, "rank");
}
