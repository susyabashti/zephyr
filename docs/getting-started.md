# Getting started

A first run with zephyr, end to end: install, log, read, verify, enable the
local embedding model, and hand the journal to an AI.

Your data lives in one directory: `~/.local/share/zephyr` by default.
Override it with `$ZEPHYR_HOME` or `--journal PATH`.

## 1. Install

The one-liner installs the latest [release](https://github.com/susyabashti/zephyr/releases)
(darwin-arm64 / darwin-x64 / linux-x64 / linux-arm64):

```sh
curl -fsSL https://raw.githubusercontent.com/susyabashti/zephyr/main/install.sh | sh
```

It verifies the tarball against the published `sha256sums.txt` and installs
to `~/.local/bin`. Pin a version with `ZEPHYR_VERSION=v0.2.1` in the
environment (or `sh install.sh v0.2.1`); change the target directory with
`$ZEPHYR_INSTALL_DIR`.

**Prefer to build from source?** Requires **Zig 0.17**, plus **cmake** and
**ninja** for the default build (the local embedding engine). Without them,
`zig build -Dno-embed=true` works and everything except `rank`/`ask` vector
modes is available:

```sh
zig build            # the binary is zig-out/bin/zephyr
just install-local   # …or, with just: ReleaseFast build into ~/.local/bin
```

An optional Python 3 stdlib-only environment is needed only for the
reference gates and for OpenTimestamps tooling.

## 2. Log and read

```sh
zephyr "fixed the auth bug, finally"
# ✓ logged seq 0

zephyr log -t work "shipped v2 to client"
# ✓ logged seq 1

zephyr today
# 2026-10-14 Wed
#   0  09:32 fixed the auth bug, finally
#   1  10:05 [work] shipped v2 to client
```

`today`, `yesterday`, `week`, and `on YYYY-MM-DD` show the entries for that
period, rendered by the same deterministic renderer the LLM view uses: one
date header per day, each entry with its sequence number and time in the
local timezone, the latest text of an amended entry (marked `(edited)`),
and a `[redacted]` marker where content was removed.

Search finds entries:

```sh
zephyr search "auth"
```

## 3. Verify

```sh
zephyr verify
# ✓ verified · 2 records
```

`verify` re-reads every segment, re-walks the hash chain, and reports the
exact record, field, and detail of any break — and exits non-zero. Pass
`--head` to include the log's head hash. Every other command verifies
before it trusts the journal, so a corrupted log refuses to serve instead
of serving stale data.

## 4. Enable semantic search (optional)

`rank` and hybrid `ask` embed entries with a small local model
(**EmbeddingGemma-300M, Q8_0**, about 313 MiB — everything stays on the
machine). There is nothing to set up: the first time the embedding surface
is used, zephyr downloads the pinned file, verifies its sha256 against the
pin in `src/embed/model.zig`, and installs it to
`~/.zephyr/models/embeddinggemma-300M-Q8_0.gguf`. You'll see:

```sh
zephyr derived rebuild --embeddings
# ✓ rebuilt · 42 words · 3 entities
# downloading embeddinggemma-300M-Q8_0.gguf (313 MiB) from huggingface.co
# ✓ model ok (sha256 verified) · ~/.zephyr/models/embeddinggemma-300M-Q8_0.gguf
# ✓ embedded · 17 entries
```

The download lines appear only on the first run; digests regenerate on
demand, so they are not listed in the output.

Prefer to manage the model yourself? It is a normal command:

```sh
zephyr model fetch            # download if missing or corrupt; no-op if verified
zephyr model fetch --force    # re-download even when verified
zephyr model status           # path, size, and whether it matches the pin
```

Need a different file? Point `$ZEPHYR_EMBED_MODEL` at it — a custom path is
never populated automatically.

The vector artifact is built by the same command and bound to the log's
head and to the model: a new entry, or a different model or engine, makes it
stale — vector/hybrid `rank` then refuses and tells you exactly what to run.

Then use it:

```sh
zephyr rank "why did the login break"          # hybrid, top 10
zephyr rank "why did the login break" --mode vector --top 5
zephyr ask "what do you know about the auth work?"
```

`rank` prints one line per hit and nothing else: the sequence number, date
and time, tags, the entry text, and the score. `ask` prints a deterministic
context pack — the question, your profile, `notes.md`, the period digest,
and the best matches — that you can paste straight to your AI. If the model
or artifact is unavailable, `ask` silently falls back to keyword matches;
it never fails over embeddings.

## 5. Make it tamper-evident

**Checkpoint** — sign the current log state:

```sh
zephyr checkpoint
# ✓ checkpoint seq 2 → anchors/checkpoint-2.zpa
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
zephyr ots-export 2026-09.zph        # writes ./2026-09.zph.head (32 bytes)
# …anchor that file with OpenTimestamps tooling (python-ots, opensketch):
#   it produces a standard v1 detached proof with a sha256 file hash
zephyr ots-stamp 2026-09.zph --proof 2026-09.ots
# ✓ ots · anchors/ots-2026-09.ots · bitcoin height …
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
with `--allow-write` to enable `add_entry`. Results are the same clean text
the CLI prints; a failing journal is reported as an error, never served
silently.

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
- `spec/` — the byte-level contracts (record format, anchors, OTS, derived
  layer, MCP, semantic).
