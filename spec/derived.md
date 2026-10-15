# Zephyr Derived Layer — Phase 7 (FROZEN)

Derived, rebuildable data over the journal: a search index, period digests,
an entity index, and a derived profile, plus `ask` and `recap` commands and
the `get_context` MCP tool. Companion to `record-format.md` and `mcp.md`.

## 1. Principles

- **The log is the only source of truth.** Derived data is a cache, never
  trusted. The journal reader only ever loads `<YYYY>-<MM>.zph` names
  (`journal.isSegmentName`), so derived files cannot affect verify.
- **Everything derived is a pure function** of (verified log, parameters).
  No wall clock, no randomness. Two builds from the same log are
  byte-identical.
- **Staleness is head binding.** Every derived artifact records the journal
  `head` it was built from. Current head ≠ stored head ⇒ stale ⇒ rebuild.
  Stale or corrupted artifacts are simply regenerated on read; nothing is
  served flagged-as-stale.
- **Derived data must never change existing answers.** `search` semantics
  stay frozen (case-insensitive substring, view rules) and remain a linear
  scan — the exact oracle. The index accelerates *retrieval* (section 3);
  indexed lookups are cross-checked against brute force in tests.
- **The machine derives; the AI judges; the user owns the words.**
  `profile.md` and digests are machine-rendered. `notes.md` is the user's
  and zephyr never modifies it. `ask`/`get_context` select context; they
  never answer.

## 2. Storage

```
<journal>/
  derived/
    index.zdi                       # binary (sections 3-4)
    digests/<start>_<end>.digest    # text artifacts (section 5)
  profile.md                        # machine-rendered (section 6); path kept from Phase 6
  notes.md                          # user-owned (section 6); zephyr never writes it
```

- Machine files are written atomically (write temp + rename, same as
  segment writes) and may be deleted at any time: the next read rebuilds.
- Nothing in `derived/` is read by the journal, verify, anchoring, or the
  MCP server's data path except through the staleness protocol below.

**Staleness protocol.** Before using a derived artifact: run the full chain
verify. If the artifact's stored head equals the current head (and, for the
binary index, its `version` byte matches and the footer hash checks), use
it. Otherwise regenerate from the verified records and overwrite. A
corrupted artifact is indistinguishable from a stale one and simply gets
rebuilt — the same trust posture as the local anchor files.

## 3. Search index (`index.zdi`, magic `ZDI1`)

A binary map of token → entry seqs, built from visible entries (view rules:
private/tombstoned excluded, redacted and amended text indexed as rendered).

```
"ZDI1" (4)  version u8  flags u8 = 0
head (32)  record_count u64be  word_count u64be
word_count × (len u8, word bytes, seq_count u32be, seqs u32be ascending)   # words sorted byte-wise
entity_count u64be
entity_count × (len u8, name bytes, kind u8, first_seq u32be, last_seq u32be, count u32be)  # sorted by name
sha256 of everything above (32)
```

- `version` starts at 1. Any change to tokenization, stopwords, or entity
  rules bumps it; an index with a foreign version is rebuilt (section 2).
- **Tokens**: lowercase ASCII words of length ≥ 2 after splitting on
  non-letters; one entry contributes each token once. Non-ASCII text is not
  indexed in v1. This tokenizer is shared by the index, digests, and `ask`
  keyword retrieval.
- **Use**: only by `ask`/`get_context` (section 7) and `derived status`.
  `search` does not use it — substring semantics cannot be reproduced from a
  token map, and the linear scan is the oracle the gate compares against.
- Determinism: all sections sorted; no timestamps. Byte-identical rebuilds
  are part of the gate (section 9).

## 4. Entities (stored in `index.zdi`)

Two kinds, both pure functions of visible entries:

- **kind 0 — tag**: every tag of every visible entry. Unambiguous.
- **kind 1 — phrase**: a maximal run of 1–4 words in entry text where each
  word begins with an ASCII uppercase and contains at least one lowercase
  letter (no ALL-CAPS acronyms), the run does **not** begin a sentence
  (sentence start = text start, or `.`, `!`, `?` followed by whitespace),
  and the run is not in the stoplist. Mid-sentence capitalized words like
  "Zephyr" or "Alice" qualify; sentence-initial "The" does not.
- `count` = number of visible entries containing the entity;
  `first_seq`/`last_seq` = the seqs of the first and last such entry.

**Stoplist discipline.** The stoplists (entity stoplist, `ask` question
stopwords) are frozen consts in core, pinned by fixture vectors, and version-
gated by the index `version` byte. Their contents are an implementation
detail tuned during Phase 7; the rule is that once the gate runs they are
frozen, and any later change is a format change.

## 5. Digests

One text artifact per period, where a period is an explicit inclusive
date range `start..end` (civil dates, view grouping rules) — no ISO week
numbers, no timezone inference beyond the entries' own offsets.

```
# zephyr-digest: period=2026-01-05..2026-01-11 range=seq 12..30 head=<64-hex>
15 entries (3 redacted)
tags: work 4, home 2, zephyr 2, ...        # count desc, then name asc
top words: zephyr 6, anchor 4, ...          # count desc, then word asc, 20 max
```

- Content is a pure function of (verified log, range): entry count, redacted
  count, tag histogram, and top-20 **token counts over the period's own
  entries** (the shared tokenizer; the index is not consulted, since it
  stores seqs, not counts). No entry text beyond markers — the entries
  themselves come from `get_entries`/the view when needed.
- The header line carries the provenance triple (period, seq range of the
  entries it covers, head at build). `recap` and `get_context` serve the
  stored artifact when fresh, regenerate when stale.
- Bounded: one line per tag (the format already bounds tags per entry) plus
  20 word lines.

## 6. Profile

The profile is **derived, not edited** — the same artifact class as a
digest. It is the standing "who is this person, per their own log" context,
and like all derived data it is a pure function of the verified log.

`<journal>/profile.md` (path unchanged from Phase 6), first line a version
header, then a bounded set of sections — each at most N lines, N frozen:

```
# zephyr-profile: v1 range=seq 0..120 head=<64-hex>
121 entries, 2026-01-01..2026-03-15 (2 redacted)
most active: 2026-02 (18 entries)
tags: work 22, zephyr 14, home 9           # kind-0 entities, top 10, count desc then name asc
people and places: Alice 9, Berlin 4, ...  # kind-1 entities, top 10
```

`v` is the profile format version (1); `range` spans the journal's seqs
(`none` for an empty journal); a section is omitted when it has no items.

- Regenerated on read when the head has moved; never served flagged-as-
  stale. An empty journal renders just the header and a `0 entries` line.
- **`notes.md`** (journal root) is the user's own words about themselves —
  free text, no format requirements, no version header, **zephyr never
  writes or rewrites it**. `zephyr profile` and `get_profile` present the
  derived profile followed by the notes under a `# notes` heading (or a
  single-line note when absent), so an AI client can tell machine-fact from
  user-voice.
- **Migration.** On the first persisting render after Phase 7, if
  `profile.md` exists and lacks the version header, its current content is
  appended verbatim to `notes.md` (blank-line separated when notes already
  exist) or written as `notes.md`, and the derived profile is written in
  its place. A user's hand-written profile is never destroyed — it becomes
  their notes. The `# notes` heading is presentation only: it is never
  written into `notes.md`. The move happens once, is atomic (temp +
  rename), and is idempotent (a versioned header means "already
  migrated"). The MCP server never migrates: it serves the derived profile
  in memory and leaves the legacy document in place until a CLI read
  migrates it.

## 7. Commands and MCP

`zephyr ask [from:to] <question...>` — deterministic context pack on stdout;
**no LLM, no network in zephyr**. It is the retrieval half of RAG; the user's
AI answers from the pack. `from:to` is `YYYY-MM-DD` or
`YYYY-MM-DD:YYYY-MM-DD` (a bare date covers that day):

1. Verify; refuse on a bad chain (same as every command).
2. Provenance line, then `# question: <question verbatim>`.
3. Derived profile; then `# notes` if `notes.md` exists.
4. Digest for the covered period — the explicit `from:to`, or the day of an
   ISO date `YYYY-MM-DD` occurring in the question, or the current week
   (Mon-Sun) in the journal's timezone.
5. Keyword retrieval: tokenize the question (section 3 tokenizer minus the
   question stopword list), look up the index (brute-force token scan when
   the index is missing), scoped to the section-4 period when one was
   resolved (all-time otherwise); take the union of matching seqs, render
   those entries in view order, capped (default 8 KiB of view text, with a
   truncation note).
6. Footer: `Answer using only the entries above; cite seqs; say so if the
   answer is not present.`

`zephyr recap [start..end]` — the digest for the period (default: current
week/month per the `get_digest` rules); regenerates the stored artifact when
stale.

`zephyr profile` — derived profile plus notes (section 6).

`zephyr derived status` — one line per artifact: short name (`index`,
`embed`, `profile`, `digest <start>..<end>`), state (`fresh`/`stale`/
`corrupt`/`missing`), and — when known — the record count and, for the
embedding artifact, the vector dimension. Plain text when piped; colored
on a TTY. `zephyr derived rebuild` forces a rebuild.

**`get_context` (MCP).** New tool on the existing server:
`get_context {question: string (required), from?: date, to?: date}` → the
section-7 pack, same bytes the CLI prints. Always advertised; not
write-gated; **read-only** — the pack is computed in memory (persist is off)
and the server never writes or migrates derived artifacts; the CLI's
`ask`/`recap`/`derived` commands are the persisting surface. `from`/`to`
follow the `ask` rules: both bound the period, a bare `from` or a bare
`to` covers that day, and neither falls back to step 4. This **amends
`mcp.md`** (tool list 5 → 6; the `get_profile` result now includes
`# notes`). The five existing tools keep byte-exact behavior; the Phase 6
freeze is on behavior that ships, and this spec was written knowing Phase 7
takes over the profile surface (mcp.md section 5). `test/phase6.zig` and
`test/mcpref.py` gain the corresponding checks and stay green for
everything they already assert.

## 8. Gate

`test/phase7.zig` (in-process, on-disk journal over in-memory I/O) and
`test/derivedref.py` (real process, independent Python re-implementation of
the ZDI1/digest/profile/pack bytes) implement the set below.

- **Rebuild determinism**: `rm -rf <journal>/derived <journal>/profile.md`
  then any read command auto-rebuilds; the rebuilt `index.zdi` is
  byte-identical to the previous build, and every `ask` pack, `recap`
  output, and profile render is identical to the pre-deletion ones.
- **Staleness**: append one entry, then one redaction; the next read
  detects head mismatch, regenerates, and the redacted period's digest
  shows the `[redacted]` marker and updated counts; the profile reflects
  the new counts on its next read.
- **Oracle agreement**: for the fixture journal, indexed keyword lookup in
  `ask` returns exactly the entries a brute-force token scan returns
  (checked in `test/phase7.zig`), for questions with and without a date
  scope.
- **Migration**: a pre-Phase 7 journal with a hand-written `profile.md`
  ends up with its exact original text inside `notes.md`, a versioned
  derived `profile.md`, and a second run changing nothing.
- **Spot-check set**: a handful of questions with known answers from the
  fixture journal (dates, counts, tag facts); run with a real AI client
  against `zephyr mcp` using `get_context` — recorded in `spec/vectors/` as
  fixture + expected answers, mirroring how `mcpref.py` freezes its
  expectations.

## 9. Out of scope

- Semantic search / embeddings (Phase 8, optional).
- Any LLM invocation, API key, or network I/O inside zephyr.
- Full-text substring indexing (the linear scan stays; revisit only if it
  stops being acceptable, which Phase 3's numbers suggest is far off).
- Profile version history (last version wins; the log already holds every
  fact the profile summarizes, so a lost profile is re-derivable).
