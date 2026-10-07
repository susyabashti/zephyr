---
name: zig-api
description: Version-aware Zig API reference covering Zig 0.15.x, 0.16.0, and 0.17.0. Use when writing, reviewing, or upgrading Zig code and you need correct, version-specific APIs — ArrayList, std.Io Reader/Writer, HTTP client, JSON, Ed25519, std.process.Init (Juicy Main), SafeAllocator, build.zig, and type-creation builtins. Also use when porting across versions or when you need to avoid outdated 0.11–0.14 patterns. For code style/idioms/assertions (not version-specific APIs), use the zig-tiger-style skill instead.
license: MIT
metadata:
  versions: "0.15.x, 0.16.0, 0.17.0"
  language: "zig"
  category: "programming-language"
---

# Zig API Reference (0.15 / 0.16 / 0.17)

A version-aware API guide for Zig. The language and standard library changed significantly
across 0.15 → 0.16 → 0.17, so **confirm the target version first, then read the reference
files (see Step 2 — all of them, not just the target version's).** Never mix APIs from
different versions — a 0.16 pattern in a 0.15 project (or vice versa) is a compile error.

## Step 1 — Determine the target Zig version

Check, in order of reliability:

1. **The project's pinned toolchain** — `zig version`, or a vendored toolchain
   (e.g. `./solana-zig/zig version`). A modified/vendored toolchain tracks a specific stable
   release, not master.
2. **`build.zig.zon`** (name/version/fingerprint) and any CI config, `Dockerfile`, or
   `.zig-version` file.
3. **What the user says** they are targeting.

If you genuinely cannot determine it, **ask.** Writing the wrong version's APIs is the most
common source of the errors this skill exists to prevent.

Supported versions: **0.15.x**, **0.16.0**, **0.17.0**.

## Step 2 — Read the reference files

| Target version | Reference file |
|----------------|----------------|
| 0.15.x         | [references/zig-0.15.md](references/zig-0.15.md) |
| 0.16.0         | [references/zig-0.16.md](references/zig-0.16.md) |
| 0.17.0         | [references/zig-0.17.md](references/zig-0.17.md) |

**Read all the reference files, not just the target version's.** Each file documents the
changes *introduced by that release*, not the complete API surface of that version. The
standard library is cumulative: an API missing from the target version's file may have been
introduced in an earlier release and carried forward unchanged (e.g. `std.Io.Timestamp` /
`std.Io.Clock` are documented under 0.16 and remain the time API in 0.17). Treating the
target file as self-contained is how carried-forward APIs get missed and changes get
misattributed to the wrong version.

- **Target version's file** — authoritative for the APIs you are about to write.
- **Earlier versions' files** — where carried-forward APIs came from, and the old shapes to
  avoid. When two files disagree about the same API, the later version's file wins for code
  targeting that later version; the earlier entry describes the pre-change shape.
- **Later versions' files** (when the target is older) — what will break when the project
  upgrades.

**Porting across versions?** Read every reference file, plus the `## Porting Strategy`
section of the source version's file.

## Local documentation first

Run `zig env` to discover installation paths — never hardcode them. Key fields: `.lib_dir`,
`.std_dir`, `.version`.

- **Language Reference**: `<lib_dir>/../doc/langref.html`
- **Std Library Source**: read files under `.std_dir` for exact signatures.
- **Std Library Docs**: run `zig std` to start a local HTTP server.

Always check local docs/source before searching the web.

## Cross-version quick reference

A bird's-eye view of what changed between the documented versions. For full details, working
examples, and the error-message→fix tables, open the version reference files.

### 0.15 → 0.16

| Area | 0.15 | 0.16 |
|------|------|------|
| Type creation | `@Type(...)` | Individual builtins: `@Int`, `@Struct`, `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral` |
| C interop | `@cImport` | `b.addTranslateC(...)` (`@cImport` deprecated) |
| I/O interface | `std.Io` ("Writergate") | `std.Io` unified — thread an `io` through all I/O/sleep/random/time calls |
| Entry point | `main()` | **Juicy Main**: `main(init: std.process.Init)` |
| Env vars / args | Global `std.os.environ` / `std.process.args` | Non-global: `init.environ_map` / `init.args` |
| Concurrency | `std.Thread.Pool` | `std.Io.Group` / `Io.async` / `Io.concurrent` |
| Networking | `std.net` | `std.Io.net` |
| Random bytes | `std.crypto.random` | `std.Io.randomSecure(io, buf)` |
| Formatting | `std.fmt.FormatOptions` | `std.fmt.Options` (`bufPrintZ` → `bufPrintSentinel`) |
| Enum conversion | `std.meta.intToEnum` | `std.enums.fromInt` |
| Build manifest | — | `build.zig.zon` requires `fingerprint`; `name` is an enum literal, not a string |
| Error sets | `RenameAcrossMountPoints`, `NotSameFileSystem`, `SharingViolation`, … | `CrossDevice`, `FileBusy`, `EnvironmentVariableMissing`, … |

### 0.16 → 0.17

| Area | 0.16 | 0.17 |
|------|------|------|
| Enum conversion | `@intFromEnum` / `@enumFromInt` | `@backingInt` / `@fromBackingInt` |
| Array repetition | `[1]T{v} ** N` | `@splat(v)` — the `**` operator is removed |
| Type punning | `@bitCast(extern struct)` | `@ptrCast(&v).*` or an `extern union` |
| Test allocator | `std.heap.DebugAllocator` | `std.heap.SafeAllocator` (thread-safe, no reuse) |
| String alloc-print | `std.fmt.allocPrint(alloc, ...)` | `alloc.print(...)` / `alloc.printSentinel(...)` |
| Type reflection | Array-of-structs `fields: []Field` | Struct-of-Arrays: `field_names` / `field_types` / `field_attrs` |
| Type builtins | `@Struct` (7 params) | `@Struct` (5 params); `@Union` (5), `@Enum` (4) |
| C interop | `@cImport` (deprecated) | **Removed** — external `translate_c` package + `Translator` |
| Build system | Single process | **Configurer** and **Maker** processes; configure-cache poisoning rules |
| Build run args | `run.addArgs(b.args)` | `run.addPassthruArgs()` |
| Build paths | `b.build_root` | `b.root` (Cache.Path) |
| ArrayList tail | `getLastOrNull()` / `getLast()` | `last()` (→ `?T`) / `last().?` / `lastPtr()` (→ `?*T`) |

## Verify the environment

```bash
scripts/check-zig-version.sh
```

Reports the installed Zig version and whether it falls within the documented range (0.15–0.17).
Set `ZIG_CMD` to point at a specific/vendored toolchain.
