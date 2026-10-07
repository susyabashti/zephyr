# Zephyr — Complete Plan

A frictionless, blazing fast, local-first journal CLI whose data is tamper-evident, compact, and designed from day one to be read by an AI. This plan is **language agnostic**: it defines behavior, byte-level contracts, and verification, never an implementation language.

---

## 1. Goals and non-goals

**Goals**

1. Capture a log entry in \~3 seconds with one command; no required tags or fields.
2. Keep a **tamper-evident** source of truth: any edit, deletion, reordering, or insertion is detected.
3. Be **storage efficient** (compact encoding, block compression).
4. Be **LLM efficient**: an AI can read the journal in few tokens and answer "what did I do on date X?" or "what do you know about me?"
5. Be **implementable in any language**: correctness is defined by a spec plus test vectors.

**Non-goals**

- Multi-user sync, collaboration, or a hosted service.
- Running or storing entries on a public blockchain (only hashes are ever published).
- True tamper-*proofing* against someone who controls the machine; the goal is tamper-*evidence* backed by external anchors.

## 2. Guiding principles

- **Capture now, understand later.** Logging never asks you to organize. The AI infers structure afterward.
- **History is append-only.** Corrections and deletions are new records; nothing is rewritten, except the explicit, logged redaction mechanism.
- **Source of truth vs. views.** The stored log is compact and canonical. Everything else (LLM view, search index, digests, profile) is derived, rebuildable, and verifiable against it.
- **Local-first and private.** No network is required to log. Anything sent to an LLM is an explicit action.
- **Verify before trust.** Any consumer (CLI views, LLM export, MCP server) checks integrity before serving data.

## 3. Threat model

| Threat | Mitigation | Phase |
| --- | --- | --- |
| Accidental corruption or crash mid-write | Atomic append, recovery rules, `verify` | 1 |
| Careless edit of a past entry | Hash chain breaks at that point | 1 |
| Deliberate edit + recomputed hashes | Signed checkpoints, external anchors | 5 |
| Tail truncation / full chain rewrite | Anchored head hash comparison | 5 |
| Backdating ("this existed earlier than it did") | OpenTimestamps on sealed segments | 5 |
| Signing-key compromise | Key stored off the journal machine where possible; checkpoints still catch past rewrites | 5 |
| Content you later want gone | Salted-commitment redaction | 5 |
| Private entries leaking to an AI provider | `private` flag excluded from LLM view and MCP | 4, 6 |

## 4. Architecture (layers)

```
CLI  ──►  Core library (append, verify, read)
                │
      ┌─────────┴──────────┐
      ▼                    ▼
 Canonical log        Derived layer (rebuildable)
 (segments, chained)  ├─ LLM view renderer
      │               ├─ search index
      ▼               ├─ digests, profile, entities
 Anchors (git,        └─ MCP server (read-only by default)
 OpenTimestamps)
```

Only the **canonical log** and **anchors** are authoritative. Deleting every derived artifact loses nothing.

## 5. Source-of-truth specification

### 5.1 Cryptographic choices (decided)

- **Hash:** SHA-256 (universally available; compatible with OpenTimestamps and most signing tools; stable for decades).
- **Signatures:** Ed25519.
- **Versioning:** every record header carries a `hash_alg` / format-version byte so a future migration is possible without ambiguity.

### 5.2 Record structure

Each record has two parts, stored in separate regions so redaction never touches the chain.

**Header (chained, never modified):**

| Field | Notes |
| --- | --- |
| `version` | format + hash algorithm identifier |
| `type` | `entry`, `amendment`, `tombstone`, `redaction`, `checkpoint` |
| `seq` | monotonic sequence number, starting at 0 |
| `timestamp` | UTC, millisecond precision |
| `tz_offset` | minutes from UTC |
| `flags` | bit field; includes reserved bit for `private`; unused bits reserved as zero |
| `target_seq` | for amendment / tombstone / redaction: the record affected |
| `commitment` | `SHA-256(salt ‖ payload)` |
| `record_hash` | `SHA-256(canonical header bytes ‖ previous record_hash)` |

**Payload (committed, redactable):**

| Field | Notes |
| --- | --- |
| `salt` | random bytes (16+) generated per record |
| `text` | UTF-8, NFC-normalized |
| `tags` | optional list of strings |

The chain depends only on headers (which include the commitment), never on the payload directly. The payload is verified against its commitment instead. This is what makes redaction possible without breaking the chain.

### 5.3 Canonical encoding

A single, fully specified byte layout: fixed field order, fixed integer widths and endianness, length-prefixed strings, no optional ambiguity. The spec states exactly which bytes are hashed. Two independent implementations must produce byte-identical records and hashes for the same input. This is enforced by test vectors (Phase 0).

### 5.4 Edits, deletes, redaction

- **Amendment:** new record with `target_seq`; the view shows the latest text and the original remains in the log.
- **Tombstone:** hides an entry from default views; the entry remains.
- **Redaction:** the content and salt of the target are physically removed from the payload region. The commitment and header stay, so the chain still verifies. A signed `redaction` record is appended noting what was removed and when. `verify` reports the entry as **redacted**, not as a failure. Any amendment payloads that quote the redacted text are redacted too.
- The salt ensures that a short, guessable entry cannot be recovered from the leftover commitment.
- Redaction only affects the live copy; old backups may still hold the content (anchors never do, since they hold only hashes).

### 5.5 Segments and storage efficiency

- Records are grouped into **segments** (default: one per calendar month).
- Within a segment, payloads are grouped into **blocks** and compressed with a standard codec named in the spec (zstd recommended; widely available).
- Headers use compact binary encoding: no repeated field names, small integer widths, varints where helpful.
- A **sealed** segment has a footer: first/last `seq`, record count, final `record_hash` (the segment head), and a footer hash. The next segment's chain starts from the previous segment's head.
- Segment files are never modified after sealing, except for payload-region redaction.
- Initial design stores every `record_hash` for exact tamper localization; Phase 3 measures the cost and may switch to implied hashes with per-block checkpoints if the size target isn't met.
- **Size target (set in Phase 3, per spec §2):** for the gate profile — 100k entries of 20-char text with one 3-char tag, monthly segments — v1 (uncompressed) measures **190 B/entry** (19,004,632 bytes across 40 segments); naive JSONL for the same entries is **94 B/entry** (ratio 2.02). The difference is the per-record tamper-evidence overhead (32-byte hash prefix, 93-byte header, 32-byte salt), the accepted cost of exact tamper localization (spec §2: store every `record_hash`). **Target: v1 stays at or under 200 B/entry on the gate profile** — a regression ceiling enforced by the `zig build roundtrip` gate. The ratio converges toward ~1.1 as entry text grows; the planned zstd payload codec (v2, spec §2) is the lever if size ever needs to come down.
- **Token target (set in Phase 4, per spec §2):** for the same entry profile (20-char text, one 3-char tag, UTC), the LLM view renders **8.80 tokens/entry** (35,215 bytes over 10k entries, measured with the standard ~4-chars-per-token heuristic) vs **23.50 tokens/entry** for the naive JSONL baseline — a ratio of **0.37**, i.e. the view fits in about a third of the tokens. **Target: the LLM view stays at or under 9.0 tokens/entry on this profile** — a regression ceiling enforced by the Phase 4 gate test. The view is the deterministic renderer of section 6; its byte layout is pinned in `spec/vectors/journals.json` (`expect.view`) and checked by both implementations.
- *Optional (Phase 5):* a Merkle root over each segment's records in the footer, so a single entry can be proven authentic without verifying the whole log.

### 5.6 Crash safety

Appends are atomic from the reader's view: write the complete record, flush to durable storage, then advance the head pointer. On startup, an incomplete trailing record is detected and discarded or quarantined; it never corrupts earlier records.

## 6. LLM view

A deterministic renderer that turns **verified** records into the smallest reasonable text, for example:

```
# 2026-09-14 Mon
09:32 fixed the auth bug, finally
14:10 [work] shipped v2 to client
16:45 (edited) call with dentist, moved to Thursday
17:20 [redacted]
```

Rules, all fixed by the spec so output is byte-identical for the same input:

- Date header once per day; times in the entry's local timezone.
- Latest amendment text shown; tombstoned entries omitted; redacted entries shown as a marker (or omitted, configurable).
- `private` entries are never included.
- Output includes a one-line provenance header: log range and head hash it was rendered from.
- The renderer **refuses** to run on a log that fails `verify` (or clearly labels the output as unverified, if the user opts in).

## 7. CLI surface

```
zephyr "text"                     quick log
zephyr log -t tag "text"          optional tags
zephyr today | yesterday | week   views
zephyr on 2026-09-14              a specific date
zephyr search "query"             keyword search
zephyr edit <id> / rm <id>        amendment / tombstone
zephyr redact <id>                redaction (confirmation required)
zephyr verify                     full integrity check; exact failure position
zephyr export --for-ai [range]    LLM view
zephyr ask "question"             retrieval + LLM answer
zephyr recap week|month           digest
zephyr checkpoint                 sign and publish a checkpoint
zephyr mcp                        start read-only AI server
```

## 8. AI access (MCP)

A read-only server exposing: `get_entries(from, to)`, `search(query, limit)`, `get_digest(period)`, `get_profile()`, `verify_status()`. `add_entry(text)` exists but is **off by default** and must be explicitly enabled. Every response carries the provenance header. If the chain is invalid, the server reports it rather than serving silently.

## 9. Derived layer

- **Search index:** full-text, rebuildable from the log.
- **Digests:** weekly/monthly summaries stored as separate files; the AI reads digests first and drills into raw entries only when needed (saves context).
- **Profile:** an AI-maintained living document (projects, people, habits, interests, goals, shifts over time). Always user-editable; raw entries are never modified by AI.
- **Entities:** people, projects, places extracted from entries.
- **Provenance rule:** every derived artifact records the log range and head hash it was derived from, so stale or unsupported summaries are detectable.
- **Redaction rule:** redacting an entry invalidates and regenerates any derived artifact built from it.

---

## 10. Phases

Every phase has a deliverable and a pass/fail gate. Do not start the next phase until the gate passes.

### Phase 0 — Spec and test vectors

**Deliverables**

- Written spec: record header/payload layout, canonical encoding, hash inputs, segment and footer layout, crash-recovery rules, LLM-view rendering rules.
- A test-vector set: example records with exact bytes and expected hashes, including amendment, tombstone, and redaction cases, plus deliberately corrupted examples with expected failures.
- Decisions frozen (see section 11).

**Gate**

- A hand-computed hash for a tiny journal matches the vectors.
- Two readers working only from the spec (no shared code) produce identical bytes for the same input.
- No field has ambiguous encoding.

### Phase 1 — Append and verify

**Deliverables**

- `log` (append) and `verify` over the chained log, one segment.
- Atomic append and crash recovery.

**Gate**

- All Phase 0 vectors pass.
- Tamper tests: flipping a byte, deleting a record, reordering, inserting a forged record, and altering a timestamp each make `verify` fail and report the exact position.
- Kill-the-process-mid-write tests leave a log that recovers cleanly.

### Phase 2 — Reading and amendments

**Deliverables**

- `today`, `yesterday`, `week`, `on <date>`, `search`, `edit`, `rm`.
- Amendment and tombstone records.

**Gate**

- Golden-output tests on a fixture journal.
- Edits and deletes change the view while `verify` still passes and the original records remain present.
- Timezone and date-boundary cases (entries near midnight, timezone changes) produce correct "on date X" results.

### Phase 3 — Segments and storage efficiency

**Deliverables**

- Monthly segments, block compression, sealed footers, payload region separation.
- Cross-segment chain linking.

**Gate**

- Round trip: write 100k synthetic entries, read back, identical.
- `verify` works across segment boundaries; tampering with a sealed segment or its footer is detected.
- Measured bytes per entry meets the target set in Phase 3 (baseline: naive JSONL; see §5.5). If the target is missed, evaluate implied hashes with block checkpoints and re-run the tamper tests.

### Phase 4 — LLM view

**Deliverables**

- Deterministic renderer and `export --for-ai`.
- `private` flag honored.

**Gate**

- Same input produces byte-identical output across runs and across independent implementations (vectors).
- Token count per entry beats raw JSON by a measured margin (target: see §5.5).
- Renderer refuses to run on a failing log.
- No `private` content ever appears in output (tested).

### Phase 5 — Signing, redaction, anchoring

**Deliverables**

- Key generation, Ed25519 signed checkpoints (head hash, count, time).
- Salted-commitment redaction with signed redaction records.
- Anchor 1: checkpoints pushed to a private git repository (or second device).
- Anchor 2 (after the format is stable): OpenTimestamps on sealed segment head hashes.
- *Optional:* per-segment Merkle roots and single-entry proofs.

**Gate**

- Truncating the tail, or fully rewriting the log with a new valid chain, is caught by comparison with an anchor.
- Redaction test: after redacting, the content and salt are gone from disk, `verify` passes and reports "redacted," and the commitment cannot be matched against guessed content.
- Signature verification works from the spec and vectors alone.
- A timestamp proof verifies independently of Zephyr.

### Phase 6 — AI access (MCP)

**Deliverables**

- Read-only MCP server with the tools in section 8.
- Provenance header on every response.

**Gate**

- Against a fixture journal with known facts, an AI client correctly answers date-specific questions ("what did I do on date X?").
- The server flags or refuses when the chain is invalid.
- `private` and redacted entries never leak through any tool.
- Write tool is disabled by default and cannot be enabled by an AI-supplied request.

### Phase 7 — Derived layer

**Deliverables**

- Rebuildable search index, digests, entities, profile.
- `ask` and `recap` commands.

**Gate**

- Deleting the index and rebuilding yields identical results.
- Every digest and profile version records its source range and head hash; a stale one is detected after new entries or redaction.
- Spot-check set: a handful of questions whose correct answers are known from the fixture journal; the AI answers them correctly using digests and entries.

### Phase 8 (optional) — Semantic search

**Deliverables**

- Embeddings over the LLM view, rebuildable from the log.

**Gate**

- On a small labeled query set it beats keyword search by a margin you set in advance. Otherwise, skip it.

---

## 11. Decisions

**Agreed**

- SHA-256 for hashing, with a version byte in every header; Ed25519 for signatures.
- Redaction via salted commitments, with signed redaction records.
- Anchoring starts with signed checkpoints in a private git repository, then adds OpenTimestamps on sealed segment head hashes.

**To finalize in Phase 0**

- Whether to include the `private` flag in v1 (recommended: yes, since adding a header field later means a format migration).
- Segment granularity (monthly assumed).
- Compression codec (zstd recommended).
- Store every `record_hash` vs. implied hashes with block checkpoints (start with stored; revisit in Phase 3).
- Where the signing key lives (off the journal machine is stronger).
- Numeric targets: bytes per entry, tokens per entry.

## 12. Definition of done (v1)

Phases 0–6 passed: you can log in one command, run `verify` and trust the result, hold external anchors that expose any rewrite, redact content when needed, and ask an AI "what did I do on date X?" through a read-only server that checks integrity first. Phases 7–8 add the "get to know me" intelligence.
