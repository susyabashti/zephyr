# Zephyr Semantic Search — Phase 8

Embeddings over the LLM view: a local embedding engine (llama.cpp linked as
a library), a rebuildable vector artifact, hybrid retrieval in `ask`, a
`rank` command, and a pre-committed evaluation gate against keyword search.
Companion to `record-format.md`, `derived.md`, and `mcp.md`.

## 1. Principles

- **The log is the only source of truth** (Phase 7, unchanged). The vector
  artifact is derived data: deletable at any time, rebuildable, never
  verified or anchored, and never read by the journal/verify/anchoring path.
- **The journal never leaves the machine.** Inference runs in-process on a
  local model. Zephyr has no network I/O (unchanged from Phases 6-7).
- **Everything derived is a pure function** of (verified log, model bytes,
  engine identity, fixed batch configuration). A rebuild on the same
  machine, model, and engine is byte-identical. Cross-machine byte identity
  is *not* promised (backend-dependent numerics); the artifact records
  everything it depends on, so a mismatch is detected, never trusted.
- **The core is engine-agnostic.** `core` sees an `Engine` interface
  (section 3); the llama.cpp binding is a separate module wired in
  `build.zig` and constructed by the CLI. Tests never link or load
  llama.cpp — a deterministic fake engine supplies the vectors.
- **The gate is pre-committed (section 8).** If the margin is not met, the
  outcome is SKIPPED and the feature is removed. No "close enough" ships.

## 2. Model and engine (pinned)

- **Model**: EmbeddingGemma-300M (Google, Gemma license), Q8_0 (QAT) GGUF.
  - File: `embeddinggemma-300M-Q8_0.gguf`, exactly 328,577,056 bytes
  - sha256: `a0f7b4e13c397a6e1b32c2de75b1f65a14c92ec524d5f674d94a4290a1c4969b`
    — verified on load; a mismatch or size mismatch is a hard, actionable
    error.
  - Output dim **768** (no MRL truncation in v1); context 2048 tokens — an
    entry plus prompt prefix is far below it.
- **Engine**: llama.cpp **b11609 (commit fcac190)**, vendored as a git
  submodule at `third_party/llama.cpp`, built by cmake as a native library;
  only the C API surface is used. Metal backend on Apple Silicon; CPU on
  Linux (other backends out of scope, section 10).
- **C binding**: a hand-written `extern` surface in the engine module
  (load, context, tokenize, batch, encode, per-token embeddings, free).
  `translate_c` only if the surface must grow. The surface is verified
  against the pinned header at implementation time.
- **Model file placement**: not in the repository. Resolution order:
  `$ZEPHYR_EMBED_MODEL` → `~/.zephyr/models/embeddinggemma-300M-Q8_0.gguf`.
  A missing model is a clean error naming the path and the download URL —
  and it degrades only the embedding surface: every other command works.
- **Build**: `zig build` compiles the submodule and links the engine into
  the CLI. `zig build -Dno-embed=true` builds without it (the embedding
  surface reports EngineUnavailable; every other command works);
  `zig build test` never requires it. On Apple Silicon the build pre-seeds
  cmake's `GGML_MACHINE_SUPPORTS_sve`/`_sme` variables: ggml's
  `GGML_NATIVE` runtime probes for those features hang forever on macOS
  arm64 (the probe binary spins on the first SVE instruction), and Apple
  silicon needs `+nosve`/`+nosme` anyway.

## 3. Engine interface (`src/core/embed.zig`)

```zig
pub const Engine = struct {
    vtable: *const VTable,
    data: ?*anyopaque,

    /// Prompt family (section 4): how the text is framed.
    pub const Kind = enum { query, document };

    pub const VTable = struct {
        /// Embed `texts`, one L2-normalized f32 vector per text, in order.
        /// The engine owns its model state and chunking.
        embed: *const fn (data: ?*anyopaque, allocator: Allocator,
            texts: []const []const u8, kind: Kind) EmbedError![][]f32,
        /// 32-byte identity: sha256 of "model sha256 | engine string".
        identity: *const fn (data: ?*anyopaque) [32]u8,
        /// sha256 of the model file the engine loaded (pinned on load).
        modelHash: *const fn (data: ?*anyopaque) [32]u8,
        dim: *const fn (data: ?*anyopaque) u32,
        deinit: *const fn (data: ?*anyopaque) void,
    };
};
```

- The CLI constructs the engine once per process (model load is the only
  slow step) and passes it to core. Core never constructs, spawns, or links
  an engine; it calls `embed`/`identity`/`dim` and `deinit`s what it was
  given.
- The llama implementation lives in `src/embed/` (own directory: C binding +
  engine); the fake engine lives in the tests.
- `embed` takes a batch; the engine chunks internally (section 4) so caller
  memory stays bounded; order is preserved.

## 4. Embedding input (frozen)

- **Entry (document side)**: `title: none | text: <the entry's exact LLM-view
  line>` — the same pinned renderer whose bytes the Phase 4 vectors freeze.
- **Query (query side)**: `task: search result | query: <question verbatim>`
  — the retrieval prompt from the EmbeddingGemma model card.
- Only **visible** entries are embedded (redacted and private never enter a
  vector). `chunk_count` equals the visible-entry count, always.
- **Pooling**: mean over the sequence's token embeddings (per-token
  embeddings from the C API; the example's approach — the pool is ours to
  choose). A/B'd on the section-8 labeled set (vector mode): mean Recall@5
  0.944 / MRR 1.000 vs last-token 0.910 / 0.938 — **mean is frozen**.
- **Batch configuration** (fixed, part of the engine identity): at most
  16 sequences and at most 2048 tokens per engine batch; engine thread
  defaults (auto); backend recorded (`metal` | `cpu`).
- The engine identity string is
  `llama.cpp-b11609|<backend>|<pooling>|prompt-v1` — any change invalidates
  stored artifacts.

## 5. Artifact (`derived/embed.zde`, magic `ZDE1`)

```
offset  bytes  field
0       4      magic "ZDE1"
4       1      format version (1)
5       1      flags (0)
6       2      pad (0)
8       4      dim (768)
12      4      chunk_count
16      32     model hash (sha256 of the model file)
48      32     engine id (section 4 identity)
80      32     journal head
112     8      record_count (verified records at build time)
120     8      seq_min (visible)
128     8      seq_max (visible)
136     ...    chunks, in seq order: seq u64 + dim x f32 (LE)
tail    32     sha256 of everything above
```

- Atomic write (temp + rename), like every derived file.
- **Staleness**: head mismatch, or model-hash / engine-id / footer mismatch
  ⇒ stale or corrupt ⇒ rebuilt by `derived rebuild --embeddings`. **Reads
  never rebuild** — a build loads a 300M model, and that is an explicit user
  act. A missing or stale artifact simply means "no vectors": retrieval
  degrades to the Phase 7 keyword behavior, which stands on its own.
- **The engine binding is checked after load.** The head check runs without
  an engine, but the model-hash/engine-id binding can only be verified once
  an engine is loaded — the read path loads one only after the head check
  passes, then verifies it (`core.embed.matchesEngine`: artifact model hash
  and engine identity against the loaded engine). A mismatch is never
  served: `ask` degrades silently to the keyword list; `rank` fails with
  the actionable rebuild message. `derived status` reports head-level
  staleness only (its fresh/stale verdict does not require an engine).
- **Size**: 768 x 4 B = 3,072 B per entry + 8 B. The gate measures and
  prints bytes/entry (Phase 3 discipline); informational ceiling 3.2 KiB.

## 6. Retrieval

- Vector score: cosine (vectors are L2-normalized, so a dot product).
- `rank` lists (section 7):
  - `keyword` — Phase 7 token retrieval (index, or brute force), top-N by
    (token hits desc, seq asc);
  - `vector` — cosine top-N (tie: seq asc);
  - `hybrid` — reciprocal rank fusion of the keyword and vector lists,
    k = 60: `score(s) = sum over lists of 1 / (60 + rank_i(s))`, ranks
    1-based; ties: seq asc.
- `ask`: when the artifact is fresh and the model is available, Phase 7
  step 5 uses the **hybrid** list in place of the keyword list (same period
  scoping, same cap, same bytes otherwise). Any failure — no artifact,
  engine binding mismatch, model absent, embed error — degrades **silently**
  to the keyword list: `ask` never reports an embedding failure. `recap` and
  `search` are untouched (frozen).
- The MCP server never loads a model and never uses the vector artifact:
  ranking stored vectors requires embedding the query, which requires the
  model, and a long-running server process does not hold 300M parameters.
  `get_context` always uses the keyword list. This amends `mcp.md` (behavior
  note; tool list unchanged).

## 7. Commands

- `zephyr rank <query...> [--mode keyword|vector|hybrid] [--top N]`
  (defaults: hybrid, N=10). Verify-first like every command. One line per
  hit: `<rank>\t<seq>\t<score, 6 decimals>\t<view line>`; a provenance line
  first, then the hits.
- `zephyr derived rebuild --embeddings` — builds `embed.zde`: loads the
  model once, embeds visible entries in seq order, writes atomically.
  Without the flag, behavior is unchanged and no model is loaded.
- `zephyr derived rebuild --embeddings` also prints
  `embeddings: <n> entries, <b> bytes/entry (derived/embed.zde)` after the
  base rebuild line.
- `zephyr derived status` — gains a line:
  `embed  head=<hex12>  dim=<d>  model=<hex12>  engine=<hex12>
  records=<n>  <fresh|stale|corrupt|missing>`; an artifact that does not
  decode (or is absent) renders `embed  head=-  <corrupt|missing>`.
  `<hex12>` is the first six digest bytes, lowercase.
- Usage text and `RunError` updated accordingly.

## 8. Gate

**Pre-committed before implementation; no moving goals.**

**Labeled set** — `spec/vectors/embed-labeled.json` plus the fixture journal
entries it points at (frozen bytes, like every other vector file): 12
(query → gold seqs) pairs — 4 synonym/paraphrase, 3 typo/plural/morphology,
2 date, 2 tag, 1 multi-entry.

**Metrics**: Recall@5 and MRR, computed by `test/semref.py --eval` from
`zephyr rank --top 5` under each mode, on the fixture, with the real model.

**Win condition (all of):**

1. hybrid Recall@5 > keyword Recall@5, margin >= 0.2;
2. hybrid MRR > keyword MRR;
3. no query where keyword has a gold in its top 5 loses it in hybrid's
   top 5 (no regressions).

**Outcome.** Win: ship as specified. Fail: the phase is recorded **SKIPPED**
in the README — the fusion wiring, artifact, engine, and `rank` are
removed; `ask`/`recap`/`get_context` keep Phase 7 retrieval. What remains
is this spec, the labeled set, and the evaluation harness — the
measurement record. (Submodule and model go with the code.)

**Automated (offline, no model — `test/phase8.zig` + `test/semref.py`):**

- ZDE1 layout: independent Python re-implementation of header/footer bytes;
  a fake-engine artifact checked field by field.
- Rebuild determinism: delete the artifact, rebuild with the fake engine,
  byte-identical.
- Staleness: an appended entry is a head mismatch; a changed fake identity
  forces rebuild, never serves.
- Visible-only: private + redacted entries in the fixture ⇒
  `chunk_count` == visible count, their seqs absent.
- Fusion: hand-computed RRF over two lists with pinned fake vectors — the
  hybrid list is exact, ties included.
- Size: bytes/entry measured and printed; ceiling check.

## 9. Trust

- Inference is local; the journal never leaves the machine through any
  default path. (An engine that does send text is a conscious, non-default
  choice — not v1.)
- The model file is hash-pinned (section 2): a tampered or wrong model is
  refused, and any artifact built under a different hash is stale.
- Vectors are derived data: unanchored, rebuildable, same exposure as
  `profile.md` (journal directory). An embedding is a lossy summary — entry
  text is not recoverable from it, but someone holding the file and the
  model can approximate similarity. Nothing stronger is claimed.
- The llama.cpp submodule is pinned to a tag and commit; bumping it changes
  the engine id and forces an artifact rebuild — never silent.

## 10. Out of scope

- MRL dimension truncation (768 full in v1).
- Chunking inside an entry (one vector per entry).
- LLM invocation, query expansion, LLM reranking.
- Model download inside zephyr (the file is placed by the user; a
  convenience script may live outside the repository).
- Backends beyond Metal (Apple Silicon) / CPU (Linux).
- Models other than the pinned one (the interface allows; the spec pins).
