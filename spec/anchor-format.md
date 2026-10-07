# Zephyr Anchor Artifact — v1 (FROZEN)

This document specifies the anchor byte format deferred by
`record-format.md` section 10 ("the anchor byte format is specified in
Phase 5"). Anchors are the external trust source that makes tail
truncation and full rewrites detectable: both produce a log that passes
the internal `verify`, but neither can reproduce an anchored head.

Frozen on 2026-10-07 (Phase 5). Changes to this document require a new
anchor version byte.

## 1. Conventions

Same as `record-format.md` section 1: big-endian integers, SHA-256,
lowercase hex. "MUST" / "MUST NOT" are normative.

## 2. Purpose

A `checkpoint` record (record-format section 10) is a normal chained
record with an empty payload; the Ed25519 signature and public key do
not fit in the record, so they are stored in a separate **anchor
artifact**. An artifact binds a journal's `(head, count, timestamp)`
state to a public key at the moment a checkpoint is taken.

Artifacts are pushed to external storage (a private git repository or a
second device) so they outlive the journal. A reader that trusts an
artifact can detect:

- **Tail truncation:** the journal is valid but ends before the anchored
  checkpoint; the anchored head is not in the chain.
- **Full rewrite:** the log is rebuilt with a new valid chain; the
  anchored head does not occur in the new chain.

An anchor is a floor, not a pin: a journal that has grown past the
anchor is consistent with it.

## 3. Artifact layout (190 bytes)

```
offset  size  field
0       4     magic          "ZPA1" (0x5A 0x50 0x41 0x31)
4       1     version        1
5       1     reserved       MUST be 0
6       32    public_key     Ed25519 public key (RFC 8032 encoding)
38      32    head           record_hash of the journal's final record
70      8     count          u64 — total record count, including the
                             checkpoint record itself
78      8     timestamp_ms   u64 — the checkpoint record's timestamp_ms
86      8     checkpoint_seq u64 — the checkpoint record's seq
94      64    signature      Ed25519 signature (section 4)
158     32    hash           SHA-256(bytes[0..158))
```

The `head` is the journal head as defined by record-format section 8
(the final `record_hash`); when the final segment is sealed it equals
that segment's `footer_head`. `count` and `timestamp_ms` together with
`head` form the signed state; `checkpoint_seq` locates the signed
record in the chain (it is not itself signed — it is bound by `head`,
which is the checkpoint record's own `record_hash`).

## 4. Keys and signing

- Ed25519 per RFC 8032. The key pair is derived **deterministically**
  from a 32-byte **seed** (RFC 8032 section 5.1.5 key generation). The
  seed is the only secret; where it is stored is the operator's choice
  (record-format section 2: off the journal machine where possible).
  The reference CLI generates it from the OS CSPRNG on first use and
  stores it at `<journal>/zephyr-key` unless a key path is supplied
  (`--key PATH` or `$ZEPHYR_KEY`).
- The signature message is exactly the input named in
  record-format section 10:

  ```
  message = head[32] ‖ count[8 BE] ‖ timestamp_ms[8 BE]     (48 bytes)
  ```

- Signing is deterministic (no randomization): the same
  `(seed, head, count, timestamp_ms)` always yields the same 190-byte
  artifact. This is what makes anchors committable to git and
  reproducible from the spec and vectors alone.

## 5. Storage and naming

- One artifact per checkpoint: `<journal>/anchors/checkpoint-<seq>.zpa`,
  where `<seq>` is the checkpoint record's seq, decimal.
- The `anchors` directory is ignored by the segment listing (only
  `YYYY-MM.zph` files are segments).
- Reference workflow: after `zephyr checkpoint`, commit the new artifact
  to the private git repository (or copy it to the second device).

## 6. Verification (the anchor check)

Run after the journal passes `verify`. Load all artifacts; the
**latest** is the one with the highest `checkpoint_seq`. If none
exist, the anchor check is skipped (anchors are optional).

The latest artifact MUST pass, in order:

1. **Well-formed:** length 190, `magic` == `"ZPA1"`, `version` == 1,
   `reserved` == 0.
2. **Artifact hash:** `SHA-256(bytes[0..158))` == `hash`.
3. **Signature:** `signature` verifies `message` (section 4) under
   `public_key` (RFC 8032 verification).
4. **Chain linkage:** the journal contains a record with
   `seq` == `checkpoint_seq` whose `record_hash` == `head` and whose
   `timestamp_ms` == `timestamp_ms`, and the journal's total record
   count is >= `count`.

Failure at any step means the journal must not be trusted: it has been
truncated or rewritten since the anchor, or the artifact itself is
corrupted. The check reports the artifact file name and the failed
step.

## 7. Vectors

`spec/vectors/anchors.json` pins:

- RFC 8032 section 7.1 known-answer pairs (seed → public key,
  signature), which validate any Ed25519 implementation; and
- full anchor artifacts (exact 190 bytes) for fixed
  `(seed, head, count, timestamp_ms, checkpoint_seq)` inputs, which
  validate the construction and the self-verification path.

Both `test/anchors.zig` (Zig, `std.crypto.sign.Ed25519`) and
`test/reference.py` (independent pure-Python Ed25519 per RFC 8032)
re-derive every pinned value from the inputs and fail on any drift.
