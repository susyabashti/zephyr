---
name: zig-gotchas
description: >
  Version-independent Zig gotchas, each verified by a failing probe: test
  discovery, multi-line strings, dangling slices, error-set algebra, integer
  casts, @memcpy, fixed-width fmt, std.json, std.Io buffering and flush,
  catch forms, allocator free-poisoning, anonymous struct coercion,
  uninstantiated function bodies, 0.17 one-liners (math.max/min,
  Target.native, never-mutated var, var discard), native-OS switching via
  builtin.os.tag, terminal-size probing (TIOCGWINSZ), errdefer block form,
  and zig build test quirks (silent success, stale .zig-cache binaries,
  spurious "failed command"), nested-slice equality, tagged-union syntax,
  child-process fd ownership, TTY/pty testing, and 0.17 env-var reading
  (empty Environ.Map, extern-C libc requirement, configure-cached options).
  Use when writing or debugging Zig, when tests mysteriously do not run,
  on segfaults or "error set" compile errors, when string, fmt, or JSON
  misbehaves, or when environment variables mysteriously never arrive.
  Companion to zig-api (version-specific APIs) and zig-tiger-style (style).
metadata:
  language: "zig"
  category: "programming-language"
---

# Zig Language Gotchas (Version-Independent)

Pitfalls of current Zig that are not version-specific API renames (that is the
`zig-api` skill) and not style rules (that is the `zig-tiger-style` skill). Every
item below was confirmed by compiling a probe against the project toolchain; the
quoted error texts are real, so recognize them in the wild.

Design priority, as always: **Safety > Performance > Developer Experience**. A
gotcha that segfaults in an unrelated function is a safety issue, not a syntax
curiosity.

## 1. Test discovery is root-file only

`zig test file.zig` and `b.addTest` run **only the test blocks declared in the
root file**. Test blocks in transitively `@import`ed files are compiled but
never discovered.

- Symptom: a test target that reports `All 0 tests passed` while the module
  obviously contains tests. A re-export module (a file that is only `pub const x =
  @import("x.zig");` lines) is the classic trap: rooting the test at it runs nothing.
- This silently green-lights builds: zero tests, zero failures, `exit 0`.

```zig
// build.zig — one artifact per file that declares tests.
const test_files = [_][]const u8{
    "src/core/records.zig",
    "src/core/view.zig",
};
for (test_files) |path| {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = target });
    const tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

- Check the reported test count after adding tests. A count that does not go up
  means the new tests are not being discovered.

## 2. Multi-line strings

The literal starts with `\\` at the beginning of a line (after leading
whitespace). Each following line that **begins** (after leading whitespace) with
`\\` is part of the string: the leading whitespace and the `\\` are stripped and
the remainder is kept verbatim — including any spaces right after the `\\`. A line
that does not begin with `\\` **terminates** the literal.

```zig
// preferred
const json =
    \\{"a": 1,
    \\ "b": [
    \\   2
    \\ ]
    \\}
;
// json is: {"a": 1,\n "b": [\n  2\n ]\n}   (note: NO trailing newline)
```

- **The literal does not end with a newline.** The newline terminating the final
  `\\` line is unescaped, so it is not part of the string. Each `\\` line
  contributes its content plus the newline *introduced by the next* `\\`.
  A byte-exact golden that should end in `\n` comes out exactly one byte short,
  and the mismatch renders invisible in a side-by-side print
  (`view mismatch (got 203 bytes, want 202 bytes)` with identical-looking text).
  To end the string in a newline, add a bare `\\` line:

```zig
const golden =
    \\line one
    \\line two
    \\
;
// golden is: line one\nline two\n
```

- A `\\` in the middle of a line (for example after a comma in an argument list)
  does not start a string: `error: expected ',' after argument`.
- **When the string is followed by more arguments, the comma gets its own
  line.** The literal ends at the final `\\` line, and that line's content
  runs to the end of the line — so the separating comma cannot sit "after"
  the string on the same line. Omit it and the parser finds the next
  argument where it expects a separator:

```zig
// avoid — `error: expected ',' after argument` at the final `\\` line
std.debug.print(
    \\line {d}
    \\final
    .{42},
);
```

  The trailing-comma "fix" is a trap: the comma is absorbed into the string
  (`"line\nfinal,"` — a byte-exact bug) and the same error still fires at
  `.{42}`.

```zig
// preferred — comma on its own line; or hoist the format string into a
// const; or make the string the last argument
std.debug.print(
    \\line {d}
    \\final
    ,
    .{42},
);
```
- A single `\` at the start of the line is a parse error:
  `error: expected expression, found 'invalid token'`.
- For large literals (test fixtures), read a file at test time instead of
  embedding it.

## 3. `if`/`else` statements require block branches

In statement position, non-block branches do not parse:

```zig
// avoid — does not compile
if (c.xor != null) data[c.offset] ^= c.xor.?;
else data[c.offset] = c.value.?;
// error: expected statement, found 'else'
```

```zig
// preferred
if (c.xor != null) {
    data[c.offset] ^= c.xor.?;
} else {
    data[c.offset] = c.value.?;
}
```

This matches the `zig-tiger-style` formatting rule (always braces unless the
whole statement fits on one line); the surprise is that the compiler rejects the
brace-less multi-line form outright.

## 4. `for` loops yield values, not pointers

`for (slice) |item|` binds `item` **by value**. To mutate an element, capture by
pointer with `*`.

```zig
fn increment_all(dst: []u8) void {
    // A pointer capture lets the loop body mutate the element.
    for (dst, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i + 1));
    }
    // A value capture is read-only: `byte = 7;` would be
    // error: cannot assign to constant
}
```

- A pointer capture requires a pointer-like operand: a slice, or an array passed
  by address. A bare array value is `error: pointer capture of non pointer type`
  — the compiler suggests the fix:

```zig
var scratch: [2]u8 = .{ 0, 0 };
for (&scratch, 0..) |*byte, i| {
    byte.* = @as(u8, @intCast(i + 1));
}
```

- Multi-operand form: `for (left, right, 0..) |l, r, i|`. All operands must have
  the same length, or one must be an infinite range.
- For indexed iteration over multiple collections, the codebase idiom is a
  `while (i < n) : (i += 1)` loop: the index and the bound stay visible, which the
  `zig-tiger-style` bounded-loop rule wants either way.

## 5. Integer casts

- **`@as` is not a cast between different integer types.**
  `@as(i64, u64_value)` fails with `error: expected type 'i64', found 'u64'`.
  Use the builtin that states the intent:

| Intent | Builtin | Check |
|---|---|---|
| Value-preserving narrowing/widening | `@intCast(x)` | runtime range check |
| Reinterpret the same-size bits | `@bitCast(x)` | none (same size only) |
| Give an untyped literal or `@intCast` its type | `@as(T, x)` | none (x must be T or untyped) |

- **`@intCast` needs a known result type.** Bare `@intCast(x)` in an expression
  position fails with `error: @intCast must have a known result type`. Bind to a
  typed declaration, or name the target with `@as`:

```zig
// preferred — the type is visible at the conversion site
const minutes: i16 = @intCast(raw);

// also fine — the compiler's own suggested form
const minute_hi: u8 = @as(u8, @intCast(raw));
```

- **The runtime shift amount of `<<`/`>>` must be `u6`.** A counter of any other
  width fails with `error: expected type 'u6', found 'u8'`. Keep the counter a
  `u6`, and if a bounded loop can increment it past 63 (a LEB128 decoder with a
  10-byte cap hits shifts `0, 7, …, 63` and then wants one more increment),
  reject the input *before* the increment instead of widening the counter.

## 6. Slices of stack-local arrays dangle

Returning a slice of a local fixed array hands out a pointer into the current
frame. It compiles, passes unit tests, and segfaults later:

```zig
// avoid — `tags[0..count]` points into this stack frame
pub fn decodePayload(bytes: []const u8) !Payload {
    var tags: [MaxTagCount][]const u8 = undefined;
    // ... fill tags ...
    return Payload{ .salt = salt, .text = text, .tags = tags[0..count] };
}
```

- The failure is not at the return. The first caller works (the frame is
  untouched), and a later loop iteration overwrites the frame, so the crash lands
  in unrelated code — usually a `memcpy` over a wild pointer.
- Fix: allocate the slice-header array from the caller's allocator, and state the
  ownership on the struct field so the next reader cannot miss it:

```zig
// preferred — tag bytes borrow from the input; the header array is allocated
pub const Payload = struct {
    /// Borrows from the input bytes.
    text: []const u8,
    /// Tag bytes borrow from the input; the slice-header array is allocated by
    /// decodePayload and freed by the caller (`allocator.free(payload.tags)`).
    tags: []const []const u8,
};
```

- Every caller must free (including validate-only callers that discard the
  result), and tests using the safe test allocator will fail the whole run on a
  leaked header array.
- `@memcpy(dst, src)` requires `dst.len == src.len` **exactly** — a debug build
  panics with `source and destination arguments have non-equal lengths`. The
  usual mistake is copying into a rest-of-buffer tail, `@memcpy(out[w..],
  data)`, where `out` is longer than `w + data.len`. Size the tail explicitly:
  `@memcpy(out[w .. w + data.len], data)`.

## 7. Error-set algebra

- A function's declared error set must be a **superset** of every callee's. The
  compiler names each missing member; fix the declaration, not the caller.
- A `switch` over an error set used as an expression is **exhaustive**. Widening
  one callee's error set (for example adding `Allocator.Error` to a decode
  function) breaks every distant reporter with
  `error: the following cases are not exhaustive`. When you add a member to a
  shared error set, search for every `switch` over it in the same change.
- Standard library functions expose a named error set — `Dir.ReadFileAllocError`,
  `segment.ParseError`, `view.RenderError` — so compose explicit unions instead of
  reaching for `anyerror`:

```zig
// preferred — every possible failure is named
pub const VerifyError = Allocator.Error || Dir.ReadFileAllocError ||
    segment.ParseError || records.DecodePayloadError;
```

- The `std.testing.expect*` helpers return `error{ TestExpectedEqual }`. A
  function with an explicit error set that `try`s them must name that member.
- In tests, free **auxiliary** allocations too (slice-header arrays, index
  scratch). The test allocator fails the entire run when the process exits with
  anything still allocated, no matter how small the leak.
- **`if (err == error.X) return err;` inside a `catch` block does not narrow
  `err`.** After the early return, `err` is still the full union, so the next
  use (passing it to a narrower parameter) fails to compile. To split one error
  out of the set — typically `OutOfMemory` from a domain set — use a `switch`:

```zig
const verification = ots.verify(allocator, proof, digest) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    else => |e| handleDomainError(e), // e: the set minus OutOfMemory
};
```

  **The `else => |e|` capture is narrowed to the remaining set** (verified
  against the project toolchain); this is the idiom instead of `@errorCast`.
- **`orelse` requires a true optional.** It does not accept an error union with
  an optional payload (`E!?T`): `error: expected optional type, found
  'error{…}?[]const u8'`. Use `catch`:
  `const magic = r.readBytes(31) catch return error.Truncated;`

## 8. Fixed-width formatting

A positive **signed** integer with a width specifier gets a `+` sign:

```zig
var buf: [16]u8 = undefined;
const signed = (std.fmt.bufPrint(&buf, "{d:0>3}", .{@as(i64, 5)}) catch unreachable);
// signed is "0+5"
const unsigned = (std.fmt.bufPrint(&buf, "{d:0>3}", .{@as(u32, 5)}) catch unreachable);
// unsigned is "005"
```

- Any fixed-width byte layout or rendered view built with `{d:0>N}` over signed
  types is broken. Format through an unsigned cast (or `@intCast` to one) when
  the value is asserted non-negative.

## 9. `comptime` is a block, not a statement modifier

```zig
// avoid — parse error
comptime assert(HeaderLen == 93);

// preferred
comptime {
    assert(HeaderLen == 93);
}
```

- Use this form for the constant-relationship assertions that `zig-tiger-style`
  requires (size invariants, ordering constraints between config values).

## 10. `std.json` (current behavior)

- A struct field omitted from the JSON is `error.MissingField` **unless the
  field has a default value**, which is then used (0.17: `fillDefaultStructValues`
  in `std/json/static.zig`). So `b: ?u32 = null` makes omission legal and the
  value parses to null — the idiomatic shape for optional API arguments — while
  a bare `b: ?u32` still forces presence. `"field": null` always parses to null.
  Freeze fixtures accordingly — always emit both `null` and real values.
- `std.json.parseFromSliceLeaky(T, allocator, bytes, .{})` takes the **type
  first**. It is strict about the input (trailing garbage is `error.SyntaxError`)
  and "leaky" in one sense only: allocations are not freed on the error path.
  That is fine with an arena or the test allocator; do not use it with a long-
  lived GPA in a tight error path.

## 11. Tooling behavior

- **`zig build test` is silent on success.** Per-test output appears only on
  failure. Use `zig build test --summary all` for the step tree, or run the test
  binary directly (`.zig-cache/o/<hash>/test`) to see every test name.

- **A green `zig build test` does not prove the exe compiles.** Test modules
  and the exe instantiate different function sets (see 19: uninstantiated
  bodies are not analyzed). A function whose body has a type error, reachable
  only from the exe — a command module the test root never imports, or a
  function no test calls — passes the test step and fails `zig build`.
  Verified on 0.17: `zig build test` green while `zig build` reported 4
  errors in exe-only functions; adding a test that instantiates one of the
  functions made the test build start catching the next bug.

- **`.zig-cache/o/` accumulates test binaries from every past build state,**
  including intermediate revisions that did not compile or that crashed. Running
  one of those stale binaries by hand reports a crash from the *old* code:

```
error: 'vectors.test.vectors: frozen byte contract' terminated with signal ABRT with stderr:
       Segmentation fault at address 0x16fa58000
       src/core/view.zig:120:49: 0x10053b36f in render (test)
                           written += (std.fmt.bufPrint(line_buf[written..], "[{s}]", .{tag}) ...);
```

  while on disk that `bufPrint` is at line 223 in a different function. The
  tell: **the quoted source line does not match the file on disk** (line number,
  function name, or both). The current code is fine; the binary is not current.
  `zig build test` only ever runs the artifacts it just built, so trust its exit
  code. To identify the current binaries directly, do a cold rebuild
  (`rm -rf .zig-cache && zig build test`) — then the `o/*/test` set is exactly
  the live test targets — or filter by the newest mtimes after a fresh build.

- `std.debug.print("... {s}", .{expr})` does **not** unpack an error union.
  Resolve the value first:

```zig
const line = (std.fmt.bufPrint(&buf, "{s}", .{time}) catch unreachable);
std.debug.print("line: {s}\n", .{line});
```

- `zig fmt` rewrites files; `zig fmt --check` exits non-zero without writing
  (the CI gate); a build step made with `b.addFmt` rewrites.

- **Test artifacts run under the build system carry the runner protocol flag.**
  `zig build` executes test binaries with `--listen=-` (a stdio protocol between
  the build and the runner). Copying that exact invocation and running the binary
  by hand panics instantly — the protocol sees EOF on its command channel:

```
0.17.0thread 559293 panic: internal test runner failure: EndOfStream
```

  Drop the `--listen=-` flag (and `--seed` if you want a stable order) to run the
  binary directly; the `failed command:` line in the build output is the build
  system's own invocation, not a shell command to reuse.

- **(0.17.0) A *successful* test step that wrote to stderr can print a red
  `failed command:` line — and the build still exits 0.** The build renders its
  error/warning messages whenever a step has any stderr, *no matter the
  result*, and the zig-test run path leaves the failed-command string set even
  on success. Any test that prints on success (a metrics block via
  `std.debug.print`) triggers this on a cold run; a warm run re-caches the step
  and the line never appears, which makes it look like a flake. Trust the exit
  code and `zig build test --summary all` (a genuinely failed step is never
  cached); do not "fix" the passing test.

- **`zig test file.zig` (and `zig build-obj file.zig`) on a file with no
  test block compiles nothing:** a file with a type error in a `pub fn`
  reports `All 0 tests passed.` and exits 0. Only code reachable from an
  instantiated test (or `main`) is analyzed — see 19. A "does this
  compile?" probe must be a test that *calls* the probed code.

## 12. A non-void value must be used

Every expression that yields a value must be bound or explicitly discarded —
calling a function whose return value you do not need is a compile error
(C/Go habit; Zig has no implicit statement call):

```
error: value of type 'u64' ignored
    try journal.appendRecord(allocator, .entry, 0, "first day", &.{}, ts, tz, false);
note: all non-void values must be used
note: to discard the value, assign it to '_'
```

```zig
// preferred — discard explicitly
_ = try journal.appendRecord(allocator, .entry, 0, "first day", &.{}, ts, tz, false);

// or bind it when the value is useful (appendRecord returns the new seq)
const seq = try journal.appendRecord(allocator, .entry, 0, "first day", &.{}, ts, tz, false);
```

- It bites most in tests, where the habit is to `try` a builder call purely for
  its side effects.

## 13. Literal braces in format strings must be doubled

`std.fmt` format strings are sequences of `{placeholder}` tokens. A literal `{`
or `}` that belongs to the *output* (JSON braces and the like) must be written
`{{` / `}}`. A lone one is parsed as a placeholder and fails at **comptime**
with an error that points inside the standard library, not at your string:

```
/opt/.../lib/zig/std/fmt.zig:130:27: error: expected . or }, found '{'
            if (b != '.') @compileError("expected . or }, found '" ++ &[1]u8{b} ++ "'");
```

```zig
// avoid — the JSON braces are parsed as placeholder syntax
std.fmt.bufPrint(&buf, "{\"ts_ms\":{d}}", .{ts});
// error: expected . or }, found '{'

// preferred — double the literal braces
const line = std.fmt.bufPrint(&buf, "{{\"ts_ms\":{d},\"tags\":[\"gen\"]}}\n", .{ts}) catch unreachable;
```

- The error names the first brace it chokes on, which can be far from where you
  look. When a comptime fmt error cites a character that is obviously literal
  text in your string, the diagnosis is almost always an unescaped brace.

## 14. An arena allocator in a hot loop grows without bound

`ArenaAllocator` never frees individual allocations. If you hand the arena to a
function that **allocates and frees on each call** (one that re-reads files on
every append, re-extends buffers), every iteration's allocations are retained:
live memory grows with the amount of work (quadratically if per-iteration size
grows). The process is eventually OOM-killed — with **no Zig output at all**,
and the kill lands far from the cause:

```
error: 'roundtrip.test.phase 3: 100k-entry round trip' terminated with signal KILL
```

(signal KILL with no panic message, not the ABRT/segfault of the stale-binary
crashes in section 11.)

```zig
// avoid — the arena retains every file read inside appendRecord
while (i < N) : (i += 1) {
    _ = try journal.appendRecord(arena.allocator(), ...);
}

// preferred — pass an allocator that actually frees; keep the arena for
// results the test must retain until the end
while (i < N) : (i += 1) {
    _ = try journal.appendRecord(std.heap.page_allocator, ...);
}
```

- This is not a leak in the section-7 sense: the arena exits "cleanly" (its
  `deinit` frees everything at once), so the test allocator never complains. The
  failure is total memory exhaustion, not a leak report.
- A small loop hides it (a few hundred iterations × hundreds of KB is
  invisible); the same code at 100k iterations dies.

## 15. `std.Io` file writers buffer silently; flush is manual (0.17)

`Io.File.writerStreaming(file, io, &buf)` copies writes into the caller's
buffer; nothing reaches the fd until the buffer is full or you flush — and
there is **no flush on process exit**. A program that writes one short line
and exits prints **nothing** (verified: empty output, exit 0). An interactive
protocol over stdio needs an explicit `try Io.File.Writer.flush(&writer)`
after every response, or the peer hangs until the buffer fills.

- `writeAll` is a method of `Io.Writer`, not `Io.File.Writer`:
  `error: no field or member function named 'writeAll' in 'Io.File.Writer'`.
  Bridge with `writer.interface.writeAll(...)`; flush with
  `Io.File.Writer.flush(&writer)` (note the different receiver).
- "Streaming" describes the file mode, not the buffering: writes are still
  buffered in `&buf`; the mode only means the data is not read back from the
  file.

## 16. Muscle-memory one-liners that no longer compile (0.17)

- `std.math.min(a, b)` / `std.math.max(a, b)` — `error: root source file
  struct 'math' has no member named 'min'` (and likewise `'max'`). Use the
  builtins `@min(a, b)` / `@max(a, b)`.
- `std.Target.native` — `error: root source file struct 'Target' has no
  member named 'native'`. Native-OS facts live only in `@import("builtin")`
  — see 22.
- A `var` that is never written is an error: `error: local variable is
  never mutated`. Read-only locals are `const`.
- `_ = x;` on a **mutable** local — `error: pointless discard of local
  variable`. `_ =` on a `const` local and on call results is fine. Either
  mutate the var without a discard (`x += 1;` alone compiles) or make it a
  `const`.
- Fill-init `[16]u8{0}` — `error: expected 16 array elements; found 1`.
  Use `std.mem.zeroes([16]u8)`.

## 17. `catch` has no `else` form, and the handler must return the value type

`expr catch else handler` does not parse in 0.17:
`error: expected expression, found 'else'`. The only forms are
`expr catch handler` and `expr catch |e| handler`; both run **only on the
error path** and the success value passes through untouched. The handler must
evaluate to the success value's type or diverge:
`fail() catch |err| @errorName(err)` is
`error: incompatible types: 'u32' and '[:0]const u8'`. To inspect the error,
use `try std.testing.expectError(error.Bang, fail())` in tests, or let the
error propagate to a scope that can branch on it.

## 18. `Allocator.free` poisons the memory it frees

In 0.17 the generic `Allocator.free` wrapper memsets the entire slice with
`undefined` before calling `rawFree` (`std/mem/Allocator.zig`,
`@memset(bytes, undefined)`). In debug builds `undefined` is 0xAA, so freeing
anything that aliases live data destroys it:

- Freeing a **string literal** or any `.rodata` slice → writes 0xAA to
  read-only data: segfault, or corrupted literals elsewhere.
- Freeing an **arena sub-slice** (or a stale copy of an arena slice) → the
  rest of the arena, including live sibling allocations, becomes 0xAA.
- **Double-free** (including the `defer` trap below) → the second free
  re-poisons memory that may have been re-allocated and reused.

Symptoms seen in the wild: a hang inside `compiler_rt.fastMemset` with a
nonsensical length (a slice header that was 0xAA'd before being iterated),
0xAA replacement characters in rendered output, segfaults writing to
`.rodata`, and slice headers read back as `0xAAAAAAAAAAAAAA...`.

- Free exactly what you allocated, once, after the last use. A sub-slice like
  `s[5..]` is not what the allocator gave you — don't free it.
- `defer x.deinit()` on a **reassigned** variable is a hidden double-free:
  defers re-evaluate the variable at scope exit, so five reassignments plus
  one `defer` free the *last* value five times. Deinit by hand right after
  use instead.
- In tests, compare/copy before freeing — an `expectEqualStrings` after
  `allocator.free(s)` reads the 0xAA'd buffer.

## 19. A function body only compiles when the function is instantiated

Referencing a function does not semantically analyze its body (verified on
0.17): `test { _ = f; }` passes even when `f`'s body has a type error,
because `f` is never instantiated. A "does this compile?" probe that only
takes the function's address proves nothing about its body. Probe by
calling: `test { _ = f(5); }`.

## 20. Inferred anonymous struct values do not coerce to a named struct

A struct literal in a position with an expected type coerces directly
(`return .{ .x = 1, .y = 2 };` is fine). A value whose type was *inferred*
as an anonymous struct does not:

```zig
pub const Point = struct { x: i32, y: i32 };
fn make() Point {
    const p = .{ .x = 1, .y = 2 };
    return p; // error: expected type 'Point', found 'make__struct_999'
}
```

Annotate the const: `const p: Point = .{ .x = 1, .y = 2 };`

## 21. `&` on a slice expression is an error (0.17)

Slicing a local array and prefixing it with `&` — a natural
"pointer into the array" habit — does not parse as you expect:

```zig
var msg: [128]u8 = undefined;
var o: usize = 32;
copyStr(&msg[o..], "|");
// .zig: error: expected array of 'u8', found '[]u8'
```

`msg[o..]` is already a value (a slice header); `&` of it is not a way to
get the underlying bytes. Verified working forms:

```zig
copyStr(msg[o..], "|");  // the bare slice — usually what was wanted
const x = (&msg)[o..];   // parens first: slice the array's pointer
```

When a raw pointer into the array is genuinely required (a C-API parameter
such as `[*:0]const u8`), slice first and take `.ptr`: `msg[o..].ptr`.

## 22. Native OS facts: `@import("builtin")` only (0.17)

There is no `std.builtin` and no `std.Target.native`:

- `std.builtin.os.tag` — `error: root source file struct 'lang' has no
  member named 'os'` (the error names `lang`, not `builtin`).
- `std.Target.native` — `error: root source file struct 'Target' has no
  member named 'native'`.

The native OS tag is a comptime enum value on the compiler-synthesized
`builtin` package:

```zig
const builtin = @import("builtin");
pub fn osTag() @TypeOf(builtin.os.tag) {
    return builtin.os.tag;
}
```

- The tag type (printed as `Target.Os.Tag`) has no name you can write:
  neither a root-level `Target` (`error: use of undeclared identifier
  'Target'`) nor a `builtin.Target` declaration exists. Name it with
  `@TypeOf(builtin.os.tag)`, or don't name it.
- A `switch` on the tag does not semantically analyze arms for other OSes —
  verified on macOS, an arm containing the nonexistent
  `std.posix.TIOCGWINSZ` under `.linux =>` compiled — so this is the guard
  for OS-specific `std.c` calls. But the switch must still be exhaustive:
  `error: switch must handle all possibilities` /
  `note: unhandled enumeration value: 'freestanding'`. List every enum
  value or add an `else` arm.

## 23. Terminal size: `winsize` is in std, `TIOCGWINSZ` is not (0.17)

The struct exists; the request constant does not:
`error: root source file struct 'posix' has no member named 'TIOCGWINSZ'`.
The request code is OS-specific, so hardcode it per OS (see 22) and probe
with `std.c.ioctl`:

```zig
pub fn terminalColumns(file: std.Io.File, request: c_int) u16 {
    var ws = std.mem.zeroes(std.posix.winsize);
    if (std.c.ioctl(file.handle, request, &ws) == 0 and ws.col > 0)
        return ws.col;
    return 80;
}
// macOS request: 0x40087468   Linux request: 0x5413
```

- The macOS constant is `_IOR('t', 104, sizeof(struct winsize))`, verified
  by computation: `0x40000000 | (8 << 16) | (0x74 << 8) | 104` =
  `0x40087468`. The Linux `0x5413` decodes to type `'T'`, nr 19, size 0
  (the UAPI literal), but it was never executed on the machine that wrote
  this — treat it as unverified until a Linux run.
- Gate on **both** `ret == 0` **and** `ws.col > 0`: on a non-tty the ioctl
  fails and the `winsize` fields are undefined; the `col > 0` check keeps a
  garbage field from leaking into the layout.

## 24. `errdefer` with an `if` body needs the block form

Bare `errdefer if (cond) { ... }` does not parse:
`error: expected ';' after statement`. Wrap the statement in a block:

```zig
errdefer {
    if (cleanup_needed) deinit();
}
```

## 25. `std.meta.eql` (and `expectEqualSlices`) compares nested slices by pointer

`std.meta.eql` — and therefore `std.testing.expectEqualSlices` /
`expectEqual` — compares inner slices shallowly: for a `[]T` the 0.17
`std/meta.zig` shallow path checks `a.ptr == b.ptr and a.len == b.len`. A
`[]const []const u8` of byte-identical tokens compares as unequal when the
inner slices come from different allocations (tokens sliced out of a
`Environ.Map`-duped value vs string literals).
`expectEqualSlices([]const u8, &.{ "less", "-R" }, a.slices())` fails even
when every byte matches, with no hint why. Fix: compare inner elements
explicitly — `try std.testing.expectEqualStrings("less", a.tokens[0]);`
(or `std.mem.eql(u8, a.tokens[0], "less")`).

## 26. Tagged-union construction: `.tag(payload)` no longer compiles (0.17)

`const v: std.process.SpawnOptions.StdIo = .file(f);` →
`error: type '@typeInfo(process.SpawnOptions.StdIo).union.tag_type.?' not a
function`. The payload goes in struct-literal form:
`const v: std.process.SpawnOptions.StdIo = .{ .file = f };`. Destructuring
is unchanged (`switch (v) { .file => |f| ... }`). StdIo is the std case that
bites: payload-less tags (`.inherit`, `.pipe`) still work, so only the
payload-carrying `.file` line errors.

## 27. `std.fmt.bufPrint` returns an error union, not an optional (0.17)

Returns `error{NoSpaceLeft}![]u8` (not the older `?[]u8`); the muscle-memory
`.?` fails: `error: expected optional type, found 'error{NoSpaceLeft}![]u8'`.
Catch like any error (`catch return error.TooLong`). Related: building an
expected byte string with a loop-built run (e.g. `=` fills) cannot use `++`
— string `++` is comptime-only; assemble the run in an `ArrayList(u8)` and
compare with `expectEqualSlices(u8, want.items, got)`.

## 28. `Child` owns the close of its fds; the parent must not close ahead (0.17)

`std.process.wait` / `std.process.kill` do not exist — the functions live on
the type: `std.process.Child.wait(&child, io)`,
`std.process.Child.kill(&child, io)`. Both `wait` and `kill` clean up the
child: they close the tracked stdin/stdout/stderr fds **exactly once**
(`childCleanupPosix`). Two failure modes, opposite sides of one constraint:

1. **Parent pre-closes a tracked fd** (classic: close the pipe-stdin write
   end after writing, then `wait`) → the cleanup close hits a closed fd →
   EBADF → `recoverableOsBugDetected()`: `panic: reached unreachable code`
   through `closeFd` / `childCleanupPosix` in `std/Io/Threaded.zig`. In
   **debug** that is `unreachable` (abort, SIGABRT); in **release**
   `recoverableOsBugDetected` is a silent no-op — and the freed fd number
   may be reused in the window, so the cleanup close may hit an unrelated
   fd. A bug that "works" in release.
2. **Parent never closes the pipe-stdin write end** (because it must not,
   per 1) → any child that reads to EOF before exiting (`cat`, `wc`,
   `less` waiting for all input) **deadlocks**: EOF only arrives from the
   cleanup close, which happens only after the child exits. `PAGER=cat`
   hangs forever.

The pattern that works: hand the child a **regular file** as stdin
(`stdin = .{ .file = f }`) — natural EOF, fd closed exactly once by the
child's cleanup (a pager uses a pid-named temp file in a private dir,
removed after the child exits). Design constraints, all 0.17, source-
verified: `StdIo.file` **dups** the fd into the child (the parent's copy
stays open — the parent closes it after `spawn`); `Child` fields (`id`,
`stdin`, …) are private (you cannot null `child.stdin` to skip the cleanup
close); `File` has no public constructor from a raw fd (no fd-level surgery
around `Child` bookkeeping); `kill` sends SIGTERM then reaps and is
"idempotent" only because `child.id` is nulled after a successful wait/kill
— calling it on a dead-unreaped child is ESRCH → `errnoBug` → panic in
debug. General rule: std's `recoverableOsBugDetected` / `errnoBug` paths
are no-ops in release and panics in debug — anything landing on them works
in one build mode and aborts (or silently mis-closes) in the other.

## 29. `Dir.*Absolute` assert absolute paths (0.17)

`deleteFileAbsolute` / `createFileAbsolute` / `openFileAbsolute` carry a
debug assert on the input: a relative path (e.g. `".tmp-foo/bar"`) →
`panic: reached unreachable code` at
`assert(path.isAbsolute(absolute_path))` in `std/Io/Dir.zig`. Resolve first:
`std.process.currentPathAlloc(io, allocator)` + join (codebase idiom:
canonicalize the data path once at entry; everything downstream is
absolute).

## 30. `/bin/true` is gone on recent macOS

`spawn` with `.exe = .detect` and `/bin/true` → `error.FileNotFound`
(ENOENT from posix_spawn) on current macOS (the `/bin` POSIX shims were
removed). `/usr/bin/true` exists on both macOS and Linux. Rule of thumb:
anything a test spawns by absolute path must be `ls`-verified on every CI
OS before the test is written.

## 31. TTY/pager tests: `script` pty is 0x0; prove the path with a fake pager

`script -q file cmd` gives the child a pty of size **0x0** (`stty size`
inside prints `0 0`); terminal-size code that falls back on 0x0 sees a
different world than a real 80x24. Set the size inside the command:
`script -q cap.txt sh -c 'stty cols 80 rows 24; exec myapp ...'`. A 0x0
pty can also **kill the child at startup** (`less` dies on a 0-row
terminal); if the code has a "write failed → direct fallback" path (EPIPE),
the 0x0 harness exercises the fallback and "passes" while the real path is
broken — tell: full un-paginated output in the typescript. Verify pager/
child-stdin paths deterministically with a **fake pager** — a `#!/bin/sh`
script that records `echo "PAGER CALLED: $@" > /tmp/pager_call.txt` then
`cat > /tmp/pager_stdin.txt` then `exit 0` — and assert on the recorded
argv, the recorded stdin bytes (EOF delivery included: `cat` only exits
when the write end is closed / the file ends), and the exit status. For
real `less`, feed a delayed `q`: `(sleep 2; printf q) | script -q cap.txt
...`. `script` propagates the child's exit status (verified:
`sh -c 'exit 3'` → 3); an aborted child reported as 6 (SIGABRT) through
`script` + `sh`.

## 32. More 0.17 one-liner burns

- `for (std.mem.splitScalar(u8, s, ' ')) |seg|` does not compile — the
  split iterator is while-driven:
  `var it = std.mem.splitScalar(u8, s, ' '); while (it.next()) |seg| { ... }`.
- Bare optional-capture expressions without the `if` keyword are invalid:
  `opt |s| s.len else 0` → error; it must be `if (opt) |s| s.len else 0`.
- `*const [N]T` does not coerce to `[]T` (const mismatch); slicing a
  `const` array yields `[]const T`, not `[]T`.
- `{d}` is not a valid fmt for `bool` (`error: invalid format string 'd'
  for type 'bool'`); use `{any}`.
- The process id is `std.posix.system.getpid()` — there is no
  `std.posix.getpid` and no `std.process.getPid` in 0.17.

## 33. Reading environment variables in 0.17: empty Map, extern-C libc, frozen options

Every one of these was verified by a build that silently did the wrong thing:

- **`std.process.Environ.Map.init(allocator)` returns an *empty* map.** It
  never loads the process environment, so `map.get("KEY")` is always null —
  with no error, no warning. To read a variable:
  - in `main`, take `init: std.process.Init` and use `init.environ_map`
    (built for you by `std.start`); core code should receive
    `*const std.process.Environ.Map` as a parameter, not read globals;
  - otherwise, wrap the C environ yourself: count entries of
    `std.c.environ`, build
    `std.process.Environ{ .block = .{ .slice = c_environ[0..count :null] } }`,
    then `std.process.Environ.containsConstant(environ, "KEY")`
    (allocation-free, cross-platform).
- **Test declarations cannot take `std.process.Init`** in 0.17 (langref:
  tests are parameterless `anyerror!void` blocks). A test that needs the
  environment must read it itself (see the extern trick below) or take an
  env map as a parameter.
- **Any extern-C reference forces an explicit libc dependency on Linux
  targets.** Not just `@import("std.c")` — even a bare
  `extern "c" var environ: [*:null]?[*:0]u8;` in a test module produces
  `error: dependency on libc must be explicitly specified in the build
  command` on Linux (macOS compiles fine, so it only surfaces in CI). Fix:
  `.link_libc = true` on the module in `build.zig` (no-op on macOS).
- **The extern identifier IS the symbol name.**
  `extern "c" var c_environ` asks the linker for `_c_environ` →
  `undefined symbol` on macOS. It must be named `environ` (resolves to
  `_environ` in libSystem, `environ` in glibc/musl).
- **Function-local extern declarations don't parse in 0.17** — neither
  `extern "c" var` nor `extern .C var` inside a function body ("expected a
  struct, enum or union"). Top-level only. (Top-level accepts the string
  form `extern "c"`, as std/c.zig itself uses.)
- **Don't hand caller env to the build via an options module.**
  `b.graph.environ_map` in `build.zig` does see the caller's environment
  (verified), but an option computed from it is frozen in the 0.17
  *configure* cache: one flag-ON run bakes `true` into the cached graph,
  and later flag-OFF runs reuse it — the flag appears to ignore you in the
  wrong direction. Read env at run time inside the binary, not at build
  time.
- **A local `const environ` shadowing a top-level `extern "c" var environ`
  is a hard error** in 0.17 ("local constant shadows declaration"), not a
  warning. Rename the locals.
- **There is no `std.posix.getenv` in 0.17** — `getenv` lives only in
  `std.c` (which trips the libc rule above).
