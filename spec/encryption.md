# Zephyr Journal Encryption — v2 (FROZEN)

This document is the source of truth for the journal's at-rest encryption. The
record header (93 bytes), the hash chain, and the segment file layout are
**unchanged** (see `record-format.md`): encryption lives entirely inside the
payload region. Two independent implementations working only from this
document must produce byte-identical envelopes and meta files for the same
inputs. Vectors live in `spec/vectors/encryption.json`; the independent
reference lives in `test/vaultref.py`.

Frozen on 2026-10-17 (issue #8). Version v2 (below, section 8) supersedes v1,
which was frozen the same day and never shipped. Changes require a new version.

## 1. Model

- One 256-bit **master key** per machine, created once with a CSPRNG, stored
  outside the segment files (the key store, section 3).
- Every record's payload is sealed individually as **payload format v2**
  (section 2). Journals are born encrypted: a fresh journal gets its key and
  meta file before its first record.
- The journal is uniform: every payload is v2 and the meta file is present.
  Journals without a meta file are v1 (section 4) and are discontinued.

## 2. Payload format v2

```
offset  size  field
0       1     format      0x02
1       24    nonce       random bytes (CSPRNG)
25      n     ciphertext  XChaCha20-Poly1305(key, nonce, AAD, plaintext)
25+n    16    tag
```

- `plaintext` is the **v1 payload body**: `text_len` (u16, big-endian) ‖
  `text` ‖ `tag_count` (u8) ‖ tags, exactly as in `record-format.md` §4
  without the 32-byte salt.
- `key = HKDF-SHA256-Expand(PRK = master, info = nonce, L = 32)` (RFC 5869;
  the master is 256 bits of uniform random, so no Extract step is required).
- `AAD` is the record header prefix bytes **[0..29)**: `version`, `type`,
  `seq`, `timestamp_ms`, `tz_offset_min`, `flags`, `target_seq`. This binds a
  ciphertext to its record identity: moving an envelope to another record, or
  rewriting a header field, breaks authentication.
- AEAD is **XChaCha20-Poly1305**: the RFC 8439 construction — the 24-byte
  nonce expands via HChaCha20 (subkey = HChaCha20(key, nonce[0..16]);
  subnonce = 0x00000000 ‖ nonce[16..24]), the Poly1305 one-time key is the
  first 32 bytes of the subkey stream at counter 0, and the ciphertext XOR
  starts at counter 1. The Poly1305 input is
  `pad16(AD) ‖ AD ‖ pad16(C) ‖ C ‖ LE64(len AD) ‖ LE64(len C)`.
- The header's `commitment = SHA-256(stored payload bytes)` (spec section 5 of
  `record-format.md`) covers the **envelope** as stored.
- **Redacted placeholder v2**: the 41-byte all-zero envelope (format, nonce,
  and tag all zero, empty ciphertext). `record-format.md` §4's 35-byte zero
  placeholder remains the v1 form.

## 3. Key stores and the meta file

### 3.1 Meta file

`zephyr.meta`, in the journal directory:

```
offset  size  field
0       4     magic       "ZPM1"
4       1     version     1
5       1     store       0 = key file, 1 = macOS keychain
6       2     key_id_len  u16, big-endian
8       n     key_id      ASCII
```

A well-formed meta file (magic, version 1, store 0 or 1, id length 1–255,
total size 8 + key_id_len) marks the journal as encrypted. An absent meta file
marks the journal as v1 (discontinued, section 4); a malformed meta file
reads as absent.

### 3.2 Key file (store 0)

`zephyr.key` in the journal directory: exactly 32 raw bytes, file mode 0600.
`key_id` is `"zephyr.key"`.

### 3.3 macOS keychain (store 1)

A generic-password item with service `"com.zephyr.journal"`, account =
`key_id` (`"master-v1"`), value = 32 raw bytes, accessibility
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (the key never leaves the
device, including in backups).

### 3.4 Store selection

Store selection happens once, at key creation: macOS prefers the keychain and
falls back to the key file when the keychain is unavailable; other platforms
use the key file. The winning store is recorded in the meta file and is the
only store consulted afterwards — a journal's key is addressed by its meta,
never by probing.

A keychain is trusted only when it can be **confirmed**: the freshly created
key is read back, and a store that reports success yet cannot return the key
it stored is unavailable — the key file takes over, and the fresh key is
discarded (a journal must never be sealed with a key that exists nowhere).
When an item with the known identity already exists, the stored key is the
machine's key and is adopted, never shadowed by a fresh one.

## 4. v1 journals — discontinued

v1 journals (segments, no meta file, unencrypted salted payloads) are
**discontinued and unsupported**: they are neither read nor migrated. Opening
one is a hard error, reported and the process exits non-zero. No migration
path exists. Existing v1 journals are the user's to re-log or discard; the
tool provides no way to recover them.

## 5. Crash completion — removed

v1 carried a transient state: a migration that crashed between the segment
rewrite and the meta write left a mixed-generation journal with no meta file,
converged on the next open. v2 has no such state: there is no migration, and
a fresh journal writes its meta before its first record, so a journal is
either empty (key and meta created first) or complete. A journal whose meta
file is lost is unreadable (its key is unaddressable) and is reported as
section 4's error, not repaired.

## 6. Verify

- **With the key** (meta present): pass 1 (structure and chain) is unchanged.
  Pass 2 additionally requires every payload to be the placeholder v2 or to
  open under AEAD, and the decrypted body to decode per `record-format.md` §4.
  Redaction rules are unchanged, with the placeholder v2 in place of the v1
  placeholder.
- **Without the key**: pass 1, plus the commitment check over the stored
  envelope, runs as normal; payloads are reported as unverified (the count is
  exposed to the caller). The CLI never reaches this path for a real journal
  (a missing key is an open-time error); the vector harness exercises it.

## 7. Limits

| Item | Limit |
| --- | --- |
| `plaintext` | same content limits as v1 (text 1–65535 bytes for entry/amendment; 0–255 tags of 1–255 bytes) |
| envelope | 41 + plaintext bytes (≤ 65583) |
| `key_id` | 1–255 ASCII bytes |
| meta file | 9–263 bytes |

## 8. Version history

- **v2** (2026-10-17): migration (§4 of v1) and crash completion (§5 of v1)
  removed — journals are born encrypted, v1 is discontinued (section 4), and
  there is no transient state (section 5). Store selection is unchanged in
  intent but a keychain create is now trusted only on a confirmed read-back
  (section 3.4), with the key file as the fallback. `spec/vectors/encryption.json`
  and `test/vaultref.py` (header) have not been produced yet; the byte
  contract is pinned by the Zig suite (`test/vault.zig`) until they exist.
- **v1** (2026-10-17): initial freeze — migration on first contact, crash
  completion on re-run. Superseded without shipping.
