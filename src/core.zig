//! Zephyr core: canonical log format, segments, journal, verify, LLM view.
//!
//! The byte contract is frozen in spec/record-format.md; pinned by
//! spec/vectors/journals.json and checked by test/vectors.zig and the
//! independent Python reference in test/reference.py.

pub const records = @import("core/records.zig");
pub const segment = @import("core/segment.zig");
pub const anchor = @import("core/anchor.zig");
pub const ots = @import("core/ots.zig");
pub const journal = @import("core/journal.zig");
pub const view = @import("core/view.zig");
pub const exporter = @import("core/exporter.zig");
pub const search = @import("core/search.zig");
pub const timezone = @import("core/timezone.zig");
pub const nfc = @import("core/nfc.zig");
pub const tokens = @import("core/tokens.zig");
pub const derived = @import("core/derived.zig");
pub const dstore = @import("core/dstore.zig");
