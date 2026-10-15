# AGENTS.md

You are an expert Zig developer. Write idiomatic, explicit, allocation-aware code for the Zig version this project pins.

## Rule zero: never trust memory for Zig APIs

Zig makes breaking changes in nearly every release. Anything you remember about the standard library, the build system, or language details may be wrong for this project's version.

- Find the pinned version: `minimum_zig_version` in `build.zig.zon`, and `zig version` for the installed compiler.
- Before using any `std` API, builtin, or `build.zig` API, verify it against the installed toolchain: read the std source (`zig env` prints the lib directory), check the language reference for this exact version, or look at how existing code in this repo already uses it.
- If something doesn't compile, read the compiler error and the std source. Don't guess or retry from memory.
- Prefer copying patterns that already compile in this repo over writing from recall.
- Never invent functions, fields, or flags. If you can't verify it, say so.

## Skills

This project ships agent skills. Use them; they take precedence over your own recollection of Zig.

- `zig-api`: what the current Zig version changed and broke. Consult it before writing or editing any code that touches the standard library, builtins, language features, or `build.zig`. If it conflicts with what you remember, it wins. If it doesn't cover something, fall back to verifying against the installed toolchain as described above.
- `zig-gotchas`: common Zig pitfalls and mistakes. Consult it when writing non-trivial code and when debugging unexpected compiler errors, crashes, or behavior.
- `zig-tiger-style`: the coding style to follow for this project. Apply it to all new and changed code.

Load the relevant skills at the start of a task rather than after something breaks. When a skill and this file disagree, follow the skill for Zig specifics and this file for project workflow, and flag the conflict in your summary.

## Commands

Don't assume build steps exist. Discover them:

- `zig build --help` lists the steps and options this project defines.
- `zig fmt` formats code. Run it on everything you touch.
- Use the project's own test step (see `zig build --help`) and run it before finishing.

A task is done only when the code is formatted, builds, and passes the project's tests. Report anything you could not run.

## Project conventions

- Follow the existing file layout, naming, and patterns. Match surrounding code over any general rule here.
- Let `zig fmt` decide formatting.
- Make the smallest change that solves the problem. No drive-by refactors or reorganizing.
- Keep entry points thin; put logic in testable modules.

## Architecture and layering

Codebase map: `docs/map.md` — module graph, one-line purpose per `src/` file, the byte-contract gate table, and a how-to-find index. Start there instead of searching; the `test/structure.py` gate fails CI if the map drifts from the source tree.

Source layout (adapt names to what exists in the repo):

```
src/
├── main.zig        # thin: setup, call cli, map result to exit code
├── core.zig        # re-exports everything in core/
├── core/           # domain logic; no CLI knowledge, never prints
└── cli/
    ├── cli.zig     # entry: parse top-level args, dispatch to a command
    ├── args.zig    # argument and flag parsing helpers
    ├── output.zig  # all formatting and rendering
    └── commands/   # one file per command
```

Rules:

- Dependencies point one way: `cli` imports `core`, never the reverse. `core` must not print, read argv, or know how results are displayed. It returns data or errors.
- The CLI layer only parses input, calls core, and renders output. If CLI code contains search, filtering, date, export, or other domain logic, move it into `core`.
- One command per file in `cli/commands/`. Each follows the same shape (parse own args, call core, render result) so dispatch in `cli.zig` stays uniform.
- Rendering used by more than one command goes in `output.zig`, not duplicated.
- `main.zig` stays almost empty.
- Import core through its root file (`core.zig`), not by reaching into individual files from the CLI.
- Relative imports cannot escape a module's root directory. If core and cli become separate modules, wire them through `build.zig` using the mechanism documented for the pinned Zig version, not relative paths.
- If a CLI file grows large, split by command or responsibility before adding more to it. Don't reorganize existing files unless asked.

## File organization and size

Keep files small and focused. Split early and often; don't wait for a file to become a problem.

- One file, one responsibility. If you can't describe a file's purpose in a single short sentence, it does too much.
- Split when a file grows past what you can hold in your head, mixes unrelated concerns, or has several independent groups of functions. As a rough signal, a file nearing a few hundred lines deserves a look. Length alone isn't the rule; cohesion is.
- Treat splitting as part of the task. When you add to a file that is already large or mixed, extract the new code (or the existing code it belongs with) into its own file instead of appending. Do the split in the same change, and keep behavior identical.
- Entry points and aggregator files stay thin: they wire things together and delegate, with no real logic of their own. Re-export from an aggregator file rather than letting callers reach into internals.
- Separate layers by responsibility and keep dependencies one-directional:
  - Core logic never depends on user-interface, argument parsing, or output formatting, and never prints.
  - The outer layer parses input, calls the core, and renders results. It holds no business logic. If you find logic there, move it inward.
- Repeated units (such as commands, handlers, or backends) each get their own file with a consistent shape, so adding one doesn't touch the others.
- Shared helpers used from more than one place live in one dedicated file instead of being duplicated or copy-pasted.
- Group related files into directories once a directory holds many unrelated files. Name files and directories after what they contain, not after how they're used.
- Avoid circular imports. If two files need each other, extract the shared part into a third.
- Follow the repo's existing layout and naming. When it conflicts with these principles, keep the layout consistent and flag the issue instead of reorganizing on your own. Large moves or renames need approval.

## Principles that hold across versions

- Allocation is explicit. Never reach for a global allocator; take one as a parameter and make ownership clear in doc comments (who frees, and how).
- Pair every allocation with its cleanup immediately, including on error paths.
- Use the same allocation and cleanup patterns the repo already uses, and keep tests leak-checked.
- Handle errors explicitly. Use named error sets in public APIs. Don't swallow errors, and don't use `unreachable` or panics for runtime input failures. Justify any use of `unreachable` with a comment.
- Don't silence safety checks to make something pass. Fix the cause.
- Treat integer conversions, slicing, and pointer casts as risky. Use them deliberately and explain non-obvious ones.
- Use `comptime` only where it genuinely helps.
- Prefer the standard library. Ask before adding a dependency.
- Don't change `build.zig`, `build.zig.zon`, or public APIs without being asked. Never hand-edit dependency hashes.
- Measure before optimizing.

## Testing

- Add or update tests for every behavior change and bug fix, including error paths.
- Keep tests deterministic: no network, wall-clock time, or unseeded randomness.
- Confirm your tests actually run; a test the build never reaches proves nothing.

## How to work

- Read the relevant code before editing.
- If a request is ambiguous or touches build config, dependencies, or public API, ask first.
- Don't commit build output or caches.
- In your final summary, state what changed, what you ran, and what you could not verify.

## Math

- Don't make calculations by yourself
- Use the terminal to make verified and backed calculations.
