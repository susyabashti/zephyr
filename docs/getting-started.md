# Getting started

A first run with zephyr, end to end: build, log, read, verify, set up the
local embedding model, and hand the journal to an AI.

## Prerequisites

- **Zig 0.17** (`zig version`).
- For the default build (with semantic search): **cmake** and **ninja**.
  Without them, build with `zig build -Dno-embed=true` — everything works
  except `rank`/`ask` vector modes.
- Optional: a Python 3 stdlib-only environment, for the reference gates and
  for OpenTimestamps tooling if you want external proofs.

Your data lives in one directory: `~/.local/share/zephyr` by default.
Override it with `$ZEPHYR_HOME` or `--journal PATH`.

## 1. Build

```sh
zig build
```

The first build compiles the pinned llama.cpp embedding engine (a few
minutes); later builds are fast. The binary is `zig-out/bin/zephyr`.

## 2. Log and read

```sh
zephyr "fixed the auth bug, finally"
# logged seq 0

zephyr log -t work "shipped v2 to client"
# logged seq 1

zephyr today
# # zephyr: seq 0..1 head=…
# # 2026-10-14 Wed
# 09:32 fixed the auth bug, finally
# 10:05 [work] shipped v2 to client
```

`today`, `yesterday`, `week`, and `on YYYY-MM-DD` show the entries for that
period, rendered by the same deterministic renderer the LLM view uses: one
date header per day, times in the local timezone, the latest text of an
amended entry (marked `(edited)`), `[redacted]` markers where content was
removed, and a provenance line naming the log state the view was rendered
from.

Search finds entries:

```sh
zephyr search "auth"
```

## 3. Verify

```sh
zephyr verify
# ok: 2 record(s), head …
```

`verify` re-reads every segment, re-walks the hash chain, and reports the
exact record, field, and detail of any break — and exits non-zero. Every
other command verifies before it trusts the journal, so a corrupted log
refuses to serve instead of serving stale data.

## 4. Set up semantic search (optional)

`rank` and hybrid `ask` embed entries with a small local model
(**EmbeddingGemma-300M, Q8_0**, about 313 MiB — everything stays on the
machine). Download the pinned file once:

```sh
mkdir -p ~/.zephyr/models
curl -L -o ~/.zephyr/models/embeddinggemma-300M-Q8_0.gguf \
  https://huggingface.co/unsloth/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf
```

Check it (the pin is in `src/embed/model.zig`):

```sh
shasum -a 256 ~/.zephyr/models/embeddinggemma-300M-Q8_0.gguf
# expect a0f7b4e13c397a6e1b32c2de75b1f65a14c92ec524d5f674d94a4290a1c4969b
```

Need it somewhere else? Point `$ZEPHYR_EMBED_MODEL` at the file.

Build the vector artifact (this loads the model and embeds every visible
entry once). It is bound to the log's head and to the model: a new entry,
or a different model or engine, makes it stale — vector/hybrid `rank`
then refuses and tells you exactly what to run:

```sh
zephyr derived rebuild --embeddings
```

Then use it:

```sh
zephyr rank "why did the login break"          # hybrid, top 10
zephyr rank "why did the login break" --mode vector --top 5
zephyr ask "what do you know about the auth work?"
```

`rank` prints a provenance line and then one line per hit: rank, seq, score,
and the entry line. `ask` prints a deterministic context pack — provenance,
the question, your profile, `notes.md`, the period digest, and the best
matches — that you can paste straight to your AI. If the model or artifact
is unavailable, `ask` silently falls back to keyword matches; it never fails
over embeddings.

## 5. Make it tamper-evident

**Checkpoint** — sign the current log state:

```sh
zephyr checkpoint
# checkpoint seq 2 (key /path/zephyr-key, anchor anchors/checkpoint-2.zpa)
```

On first use this creates a 32-byte Ed25519 seed at
`<journal>/zephyr-key` with 0600 permissions. Move that key somewhere safer
and use `zephyr checkpoint --key /secure/path` (or `$ZEPHYR_KEY`) instead —
then the journal directory alone can no longer forge a checkpoint. From now
on, `verify` also checks the latest anchor: truncation, record removal, or a
rewritten tail all fail it.

**OpenTimestamps** — get an externally witnessed timestamp for a sealed
segment. Segments seal when the month rolls over (the current, still-open
month cannot be stamped):

```sh
zephyr ots-export 2026-09            # writes ./2026-09.head (32 bytes)
# …anchor that file with OpenTimestamps tooling (python-ots, opensketch):
#   it produces a standard v1 detached proof with a sha256 file hash
zephyr ots-stamp 2026-09 --proof 2026-09.ots
# ots-stamp: ok (anchors/ots-2026-09.ots, attested at bitcoin height …)
```

`verify` re-checks every stored proof on every run, so a segment edited
after stamping is caught even if the anchors directory is intact.

## 6. Give your AI access

Two ways, both verify-before-trust:

**MCP server** — run `zephyr mcp` and point any MCP client at it:

```json
{
  "mcpServers": {
    "zephyr": {
      "command": "/path/to/zephyr",
      "args": ["--journal", "/path/to/journal", "mcp"]
    }
  }
```

The server is read-only by default and exposes `get_entries`, `search`,
`get_digest`, `get_profile`, `verify_status`, and `get_context`. Start it
with `--allow-write` to enable `add_entry`. Every successful result starts
with the provenance line of the verified log state it was read from; a
failing journal is reported as an error, never served silently.

**Export** — pull the LLM view yourself, e.g. for a one-off prompt:

```sh
zephyr export --for-ai                          # the whole log
zephyr export --for-ai 2026-10-01:2026-10-14    # a range
```

## Environment

| Variable             | Purpose                                             |
| -------------------- | --------------------------------------------------- |
| `ZEPHYR_HOME`        | journal directory (default `~/.local/share/zephyr`) |
| `ZEPHYR_KEY`         | checkpoint key file (default `<journal>/zephyr-key`)|
| `ZEPHYR_EMBED_MODEL` | model file (default `~/.zephyr/models/embeddinggemma-300M-Q8_0.gguf`) |

## What's next

- [features.md](features.md) — every feature with its current behavior, and
  the user journey.
- [plan.md](plan.md) — goals, threat model, and the phase breakdown.
- `spec/` — the byte-level contracts (record format, anchors, OTS, derived
  layer, MCP, semantic).
