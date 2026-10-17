//! LLM export (spec sections 6 and 9): the guarded path from a journal on
//! disk to LLM-view text. It verifies before rendering and refuses logs that
//! fail verify — "verify before trust" applies to every read path, AI
//! consumers included. The view's byte layout itself is frozen in
//! spec/vectors/journals.json (`expect.view`) and checked by both
//! implementations (test/vectors.zig, test/reference.py).

const std = @import("std");
const journal = @import("journal.zig");
const view = @import("view.zig");

const Allocator = std.mem.Allocator;

pub const RenderError = Allocator.Error || journal.Journal.VerifyError || journal.Journal.CollectPlaintextError ||
    view.RenderError ||
    error{
        VerifyFailed,
    };

/// Verifies the journal and renders its LLM view, optionally restricted to
/// `range` (local civil days, `end` exclusive). A log that fails verify is
/// refused with error.VerifyFailed before anything is rendered. The exact
/// failure position is not carried; a caller that must report it should run
/// journal.verify itself (cheap, failure path only).
pub fn render(allocator: Allocator, j: *const journal.Journal, range: ?view.DayRange) RenderError![]u8 {
    const result = try j.verify(allocator);
    if (!result.ok) return error.VerifyFailed;
    const recs = try j.collectPlaintext(allocator);
    defer recs.deinit();
    return view.renderRange(allocator, recs.headers, recs.payloads, range);
}
