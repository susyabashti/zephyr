# Zephyr

A local-first, tamper-evident journal CLI, designed from day one to be read by an AI.

Log in one command, in about three seconds. The journal is an append-only, hash-chained log: any edit, deletion, or reordering breaks the chain, and `zephyr verify` tells you exactly where. When you want external backing, sign checkpoints and anchor sealed segments with OpenTimestamps — after that, any rewrite or backdating is provable.

No network is required to log. Everything an AI reads is an explicit action, and every AI-facing output carries the provenance of the verified log state it was read from.

## Install

One line, from a [release](https://github.com/susyabashti/zephyr/releases):

```sh
curl -fsSL https://raw.githubusercontent.com/susyabashti/zephyr/main/install.sh | sh
```

The installer detects your platform, downloads the matching tarball, verifies it against the published `sha256sums.txt`, and installs the binary to `~/.local/bin` (override with `$ZEPHYR_INSTALL_DIR`). Pin a version with `ZEPHYR_VERSION=v0.2.1` or `sh install.sh v0.2.1`. Supported targets: macOS (Apple Silicon and Intel) and Linux (x86-64 and ARM64).

Upgrading is the same one line: everything the CLI keeps (journal, model, keys) lives in your home directory, so the install is a single-file replacement.

### Build from source

Requires **Zig 0.17**. The default build compiles a pinned llama.cpp as a native static library (the local embedding engine), which needs **cmake** and **ninja** installed. On macOS it enables Metal; elsewhere it uses CPU.

```sh
zig build
```

Or build without the embedding engine — `rank`/`ask` vector modes then report `EngineUnavailable`, and everything else works unchanged:

```sh
zig build -Dno-embed=true
```

The binary lands in `zig-out/bin/zephyr`.

## Quick start

Your journal lives at `~/.local/share/zephyr` (override with `--journal PATH` or `$ZEPHYR_HOME`). It is created on first write.

```sh
zephyr "fixed the auth bug, finally"     # quick log
zephyr log -t work "shipped v2"          # with tags
zephyr today                             # today's entries
zephyr week                              # this week, Monday through Sunday
zephyr search "auth"                     # keyword search
zephyr verify                            # full integrity check
zephyr export --for-ai                   # the LLM view of the log
zephyr ask "what did I do on Friday?"    # deterministic context pack for your AI
zephyr mcp                               # read-only MCP server on stdio
```

The whole command set:

```
zephyr "text"                     quick log
zephyr log [-t TAG]... "text"     log with optional tags
zephyr today | yesterday | week   entries for today, yesterday,
                                  or the current week (Mon-Sun)
zephyr on YYYY-MM-DD              entries on a specific date
zephyr search "query"             keyword search
zephyr ask [from:to] <question...>
                                  deterministic context pack for
                                  the user's AI: profile, notes,
                                  period digest, keyword matches.
                                  from:to is YYYY-MM-DD[:YYYY-MM-DD]
zephyr recap [start..end]         period digest (default: the
                                  current week, Mon-Sun)
zephyr profile                    derived profile plus notes.md
zephyr derived status|rebuild     inspect or force-rebuild the
                                  derived artifacts; `rebuild
                                  --embeddings` also builds the
                                  vector artifact (loads the model)
zephyr rank <query...> [--mode keyword|vector|hybrid]
                                  [--top N]  ranked retrieval;
                                  default: hybrid, top 10
zephyr model fetch [--force]     download the pinned embedding
                                  model (auto-downloaded on first
                                  use of the embedding surface)
zephyr model status             where the model lives, and
                                  whether it matches the pin
zephyr edit <seq> [-t TAG]... "text"
                                  amend an entry (tags kept unless
                                  -t is given)
zephyr rm <seq>                   hide an entry (tombstone)
zephyr redact <seq> [--yes]       remove an entry's content from the
                                  file (headers and chain are kept)
zephyr checkpoint [--key PATH]    sign the journal state into an anchor
                                  artifact (anchors/checkpoint-<seq>.zpa)
zephyr ots-stamp <segment> --proof <path>
                                  attach a standard OpenTimestamps
                                  proof of a sealed segment's footer
                                  head (anchors/ots-<YYYY-MM>.ots)
zephyr ots-export <segment> [--out <path>]
                                  write the segment's 32-byte footer
                                  head for external OTS tooling
zephyr verify                     full integrity check (plus the
                                  anchor checks, when anchors exist)
zephyr export --for-ai [range]   LLM view of the log (refuses a
                                  failing log); range: YYYY-MM-DD or
                                  YYYY-MM-DD:YYYY-MM-DD
zephyr mcp [--allow-write]      start the read-only MCP (AI) server
                                  on stdio; --allow-write enables
                                  the add_entry tool
```

See [docs/features.md](docs/features.md) for what each one does and how it behaves, and [docs/getting-started.md](docs/getting-started.md) for a guided first run.

## How it stays honest

- **Hash chain.** Every record header carries `SHA-256(canonical header ‖ previous hash)`; segments chain through their sealed footer head. `zephyr verify` reports the exact position of any break.
- **Append-only history.** Edits are *amendments*, deletions are *tombstones* — the original stays in the log, and the view shows the latest. `redact` is the only operation that physically removes content: the salted commitment and the chain are kept, so the redaction is visible and verifiable.
- **Signed checkpoints.** `zephyr checkpoint` appends a checkpoint record and writes a 190-byte Ed25519-signed anchor binding the log's head hash and record count. A truncated or rewritten journal fails `verify`'s anchor check.
- **OpenTimestamps.** `zephyr ots-export` writes a sealed segment's 32-byte footer head; anchor that file with any OpenTimestamps tooling, then `zephyr ots-stamp` verifies and stores the proof. Backdating a segment is then detectable; `verify` re-checks every stored proof.
- **Private by construction.** No network I/O in the hot path, the model for semantic search runs locally, and the MCP server verifies before it serves a single byte.

## Data layout

```
~/.local/share/zephyr/          # $ZEPHYR_HOME or --journal PATH
├── 2026-10.zph                 # monthly segments (the canonical log)
├── anchors/
│   ├── checkpoint-<seq>.zpa    # signed anchor (190 bytes)
│   └── ots-<YYYY-MM>.ots       # OpenTimestamps proofs
├── derived/                    # rebuildable; deleting it loses nothing
│   ├── index.zdi               # search index
│   ├── embed.zde               # vector artifact (ZDE1), Phase 8
│   └── digests/…digest         # period digests
├── profile.md                  # derived profile (v1)
├── notes.md                    # your notes; zephyr never rewrites it
└── zephyr-key                  # 32-byte checkpoint seed, 0600
                                # (created on first checkpoint)
```

Environment variables: `ZEPHYR_HOME` (journal directory), `ZEPHYR_KEY` (checkpoint key file), `ZEPHYR_EMBED_MODEL` (model file override).

## Semantic search (Phase 8)

`rank`, hybrid `ask`, and `derived rebuild --embeddings` use a small embedding model that runs fully locally: **EmbeddingGemma-300M, Q8_0** — 328,577,056 bytes, SHA-256 `a0f7b4e13c397a6e1b32c2de75b1f65a14c92ec524d5f674d94a4290a1c4969b`, linked in via the pinned llama.cpp submodule (Metal on macOS, CPU elsewhere).

The model downloads itself: the first `rank --mode vector|hybrid` or `derived rebuild --embeddings` at the default location fetches the pinned file (~313 MiB), verifies its sha256, and installs it to `~/.zephyr/models/` — the file is only ever put in place after verification, and an interrupted download never leaves a half file behind. Manage it explicitly any time:

```sh
zephyr model fetch            # download if missing or corrupt; no-op if verified
zephyr model fetch --force    # re-download even when verified
zephyr model status           # path, and whether it matches the pin
```

Prefer your own copy? Point `$ZEPHYR_EMBED_MODEL` at the file — a custom path is never populated automatically.

Then build the vector artifact (auto-fetch happens here too):

```sh
zephyr derived rebuild --embeddings
```

Without the artifact, `rank --mode vector|hybrid` fails with `EmbeddingsUnavailable` and tells you what to run; `rank --mode keyword` (and every other command) works with no model at all.

## Development

If you have [`just`](https://github.com/casey/just), the [justfile](justfile) covers the common tasks (`just build`, `just test`, `just gates`, `just install-local`, `just release`…). Directly:

```sh
zig build             # build the CLI (+ llama.cpp static library)
zig build test        # core unit tests + phase gate suites
zig build fmt         # format check (src, test, build.zig)
zig build roundtrip   # slow: 100k-entry round trip + size measurement
```

Correctness is defined by the byte-level contracts in [`spec/`](spec/) and enforced by two independent implementations: the Zig code and the Python reference in `test/`. The gates run against the built binary and compare bytes:

```sh
python3 test/reference.py --check    # spec vectors: records + anchors
python3 test/otsref.py --check       # OpenTimestamps vectors + corruption
python3 test/mcpref.py --check       # MCP server behavior
python3 test/derivedref.py --check   # derived artifacts, byte-for-byte
python3 test/semref.py --check       # semantic layer (add --eval for the retrieval eval)
```

## Releasing

Releasing is a tag push — the [release workflow](.github/workflows/release.yml) builds ReleaseFast binaries for all four targets (macOS arm64/x64, Linux x64/arm64), packages tarballs, publishes `sha256sums.txt`, and uploads everything to the GitHub release:

```sh
# 1. on a clean, tested tree: bump cli.Version in src/cli/cli.zig to X.Y.Z
git commit -am "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main vX.Y.Z
```

The first tag of the day doubles as the CI smoke test for the release path. Full procedure, the artifact layout, and how users verify checksums: [docs/releases.md](docs/releases.md).
