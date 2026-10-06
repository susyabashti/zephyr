//! Frozen text rules for Zephyr v1 (spec section 4.1).
//!
//! Text and tags must be valid UTF-8, contain no C0/C1 control characters, and
//! contain no combining marks (Unicode categories Mn/Mc/Me). The last rule is a
//! frozen strict subset of UAX #15 NFC: precomposed text passes unchanged, and
//! decomposed input is rejected instead of being silently mis-stored.

const std = @import("std");
const mark_ranges = @import("mark_ranges.zig");

pub const Error = error{
    BadUtf8,
    ControlCharacter,
    CombiningMark,
};

/// Validates a text or tag byte string against the frozen rules.
pub fn checkText(bytes: []const u8) Error!void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b0 = bytes[i];
        if (b0 < 0x80) {
            // ASCII fast path. 0x7F (DEL) is C0 control space.
            if (b0 < 0x20 or b0 == 0x7F) return error.ControlCharacter;
            continue;
        }
        // C1 range U+0080..U+009F encodes as 0xC2 0x80..0x9F.
        if (b0 == 0xC2 and i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9F) {
            return error.ControlCharacter;
        }
        const n = std.unicode.utf8ByteSequenceLength(b0) catch return error.BadUtf8;
        if (i + n > bytes.len) return error.BadUtf8;
        const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch return error.BadUtf8;
        if (isCombiningMark(cp)) return error.CombiningMark;
        i += n - 1;
    }
}

fn isCombiningMark(cp: u21) bool {
    // Binary search over the merged, non-overlapping range table.
    const ranges = mark_ranges.ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = @divFloor(lo + hi, 2);
        const range = ranges[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

test "accepts plain ascii and precomposed utf-8" {
    try checkText("hello world");
    try checkText("caf\u{E9} \u{20AC} \u{05D0}");
}

test "rejects combining marks" {
    // "e" + combining acute (U+0301) instead of precomposed "e-acute".
    try std.testing.expectError(error.CombiningMark, checkText("e\u{301}"));
    try std.testing.expectError(error.CombiningMark, checkText("\u{0915}\u{0344}"));
}

test "rejects control characters" {
    try std.testing.expectError(error.ControlCharacter, checkText("a\nb"));
    try std.testing.expectError(error.ControlCharacter, checkText("a\rb"));
    try std.testing.expectError(error.ControlCharacter, checkText("a\tb"));
    try std.testing.expectError(error.ControlCharacter, checkText("a\u{7F}"));
    try std.testing.expectError(error.ControlCharacter, checkText("a\u{85}"));
}

test "rejects invalid utf-8" {
    try std.testing.expectError(error.BadUtf8, checkText(&[2]u8{ 0x61, 0xC3 }));
    try std.testing.expectError(error.BadUtf8, checkText(&[2]u8{ 0xC3, 0x28 }));
    try std.testing.expectError(error.BadUtf8, checkText(&[1]u8{0xFF}));
}
