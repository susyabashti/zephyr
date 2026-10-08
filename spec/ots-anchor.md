# Zephyr OpenTimestamps Anchor — v1 (FROZEN)

This document specifies the second anchor kind deferred by
`record-format.md` section 10 ("OpenTimestamps on sealed segment head
hashes") and closes the Phase 5 gate "a timestamp proof verifies
independently of Zephyr": a Zephyr timestamp proof is a **standard
OpenTimestamps v1 detached-timestamp file** (`.ots`) that third-party
OpenTimestamps tooling can verify against the same 32-byte document.

Frozen on 2026-10-07 (Phase 5b). Changes to this document require a new
format version.

## 1. Conventions

Same as `record-format.md` section 1: SHA-256, lowercase hex. "MUST" /
"MUST NOT" are normative. The OTS byte format follows
`opentimestamps/python-opentimestamps` (master, modules
`opentimestamps/core/serialize.py`, `op.py`, `notary.py`, `timestamp.py`,
`opentimestamps/bitcoin.py`), which this document re-states in full for
the subset Zephyr uses.

## 2. What is stamped

The stamped document is the **`footer_head` of a sealed segment** (the
32-byte `head` field of the 88-byte footer, record-format section 5).
`file_digest = SHA-256(footer_head[32])`.

`footer_head` — not the segment file — is the stamped object for two
reasons:

- **Redaction invariance.** Redaction of a sealed segment (record-format
  section 6) replaces payload bytes with the placeholder and patches
  `payload_region_len`; the footer is copied byte-identically, and the
  footer hash covers only `(first_seq, last_seq, count, head)`. A file
  hash would change on redaction and break every timestamp; `footer_head`
  does not.
- **Phase 5 wording.** The deferral names "sealed segment **head
  hashes**".

A proof binds a segment's final state: any rewrite or rollback of the
sealed records changes `footer_head` and is detected.

## 3. File format (`.ots`)

A detached timestamp file is exactly:

```
offset  size  field
0       31    header magic  00 "OpenTimestamps" 00 00 "Proof" 00
                              bf 89 e2 e8 84 e8 92 94
31      1     major version 1
32      1     file_hash_op  08 (OpSHA256, the only op Zephyr accepts;
                              the digest length is 32)
33      32    file_digest   SHA-256 of the stamped document (section 2)
65      *     timestamp     the proof tree (section 4)
```

No bytes may follow the tree. Zephyr additionally refuses files over
1 MiB (local policy; calendar proofs for 32-byte documents are a few
hundred bytes).

## 4. The proof tree

The tree is a proof that the `file_digest` is committed by one or more
attestations. Each node is a 32-byte or shorter message; an entry of a
node is either an **attestation** (a leaf claim) or an **op** (an edge
to a child node). Serialization of one node: zero or more entries
prefixed with `0xFF`, then one final entry **without** the prefix.
An entry is:

```
00                      attestation:
                          8 bytes tag + varbytes(payload)
<op tag> [arg] <child>  op: tag, then a varbytes argument for binary
                          ops (1..4096 bytes), then the child node
```

`varbytes` is a LEB128 length (unsigned little-endian base 128, the
varuint of `serialize.py`) followed by that many bytes. The child node's
message is **not stored**: it is the result of applying the op to the
parent's message, so parsing the tree recomputes every message, and a
proof only parses when every edge is consistent. A node with zero ops
must have at least one attestation (the final entry must terminate).

Ops Zephyr accepts (tags per `op.py`):

```
tag  name     result
08   sha256   SHA-256(msg)
f0   append   msg ‖ arg
f1   prepend  arg ‖ msg
```

All other tags — including `f2` (reverse) and `f3` (hexlify) — are
rejected. Limits, matching the reference implementation:

- a message an op is applied to: at most 4096 bytes;
- an op argument: at least 1, at most 4096 bytes;
- an op result: at most 4096 bytes;
- an attestation payload: at most 8192 bytes;
- a pending attestation URI: at most 1000 bytes, characters
  `[A-Za-z0-9-._/:]` only;
- tree depth: at most 256.

Attestations (8-byte tags per `notary.py`):

```
tag                kind        payload
0588960d73d71901   bitcoin     LEB128 block height
06869a0d73d71b45   litecoin    LEB128 block height
83dfe30d2ef90c8e   pending     varbytes URI (a remote calendar promise)
<other 8 bytes>    unknown     opaque bytes (accepted, reported)
```

A bitcoin attestation on a node of message M claims that M is the
merkle root of the Bitcoin block at the stated height; a genuine proof's
root message therefore equals the block's merkle root, and the op chain
connects the `file_digest` to that root (for Bitcoin-backed proofs,
double SHA-256 pairs via `append`/`prepend` + two `sha256` edges per
level — the Satoshi-doubling merkle path).

## 5. Storage and naming

- One proof per sealed segment month:
  `<journal>/anchors/ots-<YYYY-MM>.ots`, where `<YYYY-MM>` is the
  segment's file name without `.zph`.
- Re-stamping a month overwrites the previous proof.
- The `anchors` directory is ignored by the segment listing (only
  `YYYY-MM.zph` files are segments); only files matching
  `ots-<YYYY-MM>.ots` with a valid month are treated as OTS anchors —
  other names in `anchors/` (e.g. `.zpa` artifacts) are left alone.

## 6. Verification

### 6.1 What Zephyr checks

`zephyr verify` runs, for **every** OTS anchor present, after the
journal passes `verify` and the checkpoint-anchor check:

1. the referenced segment `<YYYY-MM>.zph` exists and is sealed;
2. the proof is well-formed per sections 3–4 (magic, version, hash op,
   tree structure, limits, clean end of file);
3. `file_digest` == `SHA-256(footer_head)` of that segment.

A failure at any step fails the journal: `FAIL: ots anchors/ots-<YYYY-MM>.ots: <reason>`.

### 6.2 What Zephyr does not check (trust model)

Zephyr is local-first and dependency-free: it performs no network
verification and holds no block headers. It does **not** check that a
bitcoin attestation's root message is actually the merkle root of the
claimed block — that is the job of standard OpenTimestamps tooling,
which reads the very same `.ots` file. A forged proof passes Zephyr's
structural check but fails external verification; a proof Zephyr
reports as `ok` is a structurally sound binding of the segment's
`footer_head` to an attestation, and its authenticity rests on the
calendar/registrar the operator used when stamping (plus, for Bitcoin-
backed proofs, the Bitcoin chain's confirmation depth — a deep reorg
can invalidate a proof's attestation, the standard OTS caveat).

The two anchor kinds complement each other:

- **checkpoint anchor** (`.zpa`): detects tail truncation and full
  rewrites of the *journal* (it binds the journal head and count).
- **OTS anchor** (`.ots`): binds the *content* of a sealed segment to an
  external time source; detects rollback or rewrite of that segment's
  records. A journal truncated *after* an intact sealed segment passes
  the OTS check — the checkpoint anchor catches the truncation.

## 7. CLI

```
zephyr ots-stamp <segment> --proof <path>
```

Verifies the journal, reads the sealed segment's `footer_head`, verifies
the supplied standard `.ots` proof against `SHA-256(footer_head)`, and
writes it to `anchors/ots-<YYYY-MM>.ots` (the month from the segment
name). Refuses: unsealed segment, missing segment, unreadable proof,
structurally invalid proof, and a proof whose `file_digest` does not
match the segment. The proof is the operator's: it typically comes from
an OpenTimestamps calendar (`ots-stamp -u <calendar-uri> <file>` from
the reference client, or any OTS registrar). Zephyr never fetches
proofs itself.

```
zephyr ots-export <segment> [--out <path>]
```

Writes the segment's 32-byte `footer_head` to a file (default
`<segment name>.head` in the current directory). This is the document
the calendar hashes and the file standard tooling verifies against:

```
ots verify --file 2026-09.head --timestamp anchors/ots-2026-09.ots
```

independent verification of the proof, with no Zephyr involvement.

`zephyr verify` reports each OTS anchor:

```
ots: ok (ots-2026-09.ots, attested at bitcoin height 920001)
```

listing every attestation found (bitcoin/litecoin heights, pending URIs,
unknown tags).

## 8. Vectors

`spec/vectors/ots.json` pins two Bitcoin-anchored proofs produced by the
independent Python reference (`test/otsref.py --gen`):

- `bitcoin-block-586` — mainnet block 586 (first block with three
  transactions), pinned from the upstream
  `opentimestamps/python-opentimestamps` `tests/test_bitcoin.py`; the
  committed message is a 32-byte spent-transaction hash appearing in a
  block input; the proof runs through the Satoshi-doubling merkle path
  and is attested at height 586. No Zephyr document is bound to this
  vector (it pins the proof format and construction, not the document
  binding).
- `opreturn-synthetic` — a synthetic single-coinbase legacy block whose
  coinbase commits `SHA-256(document)` via `OP_RETURN`, the shape of a
  real calendar commitment; the stamped document is a fixed 32-byte
  value standing in for a segment's `footer_head`; the proof is a single
  coinbase path to the block's merkle root, attested at a fixed height.

Each vector stores the full raw block hex, so the checker
independently recomputes the txids and merkle root from the block
itself and confirms the attested root is the block's real merkle root —
the pin is auditable without trusting any precomputed digest. When the
vector binds a document, the checker re-derives `file_digest =
SHA-256(document)`. `test/ots.zig` (Zig) and `test/reference.py` (via
`test/otsref.py`) both re-verify the pinned bytes from the pinned
inputs and reject the corruption suite. The pinned proofs were
additionally cross-checked against the upstream
`python-opentimestamps` library, which parses them and verifies the
bitcoin attestation against the raw block headers.
