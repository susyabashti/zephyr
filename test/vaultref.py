#!/usr/bin/env python3
"""Independent reference for Zephyr journal encryption (spec/encryption.md).

Payload format v2: HKDF-SHA256-Expand (RFC 5869, no Extract — the master is
uniform random) then XChaCha20-Poly1305 (RFC 8439 via HChaCha20, as in
spec/encryption.md section 2). The meta file codec is section 3.1.

Stdlib only, deliberately independent of src/core/vault.zig. The crypto core
is pinned against the public libsodium HChaCha20 vectors and the RFC 8439
ChaCha20-Poly1305 AEAD vector; the envelope byte contract is the agreement of
this file with the Zig implementation on the same inputs.

The gates that spawn the CLI (derivedref, mcpref, semref) render their fixture
journals through `install_v2`: v1 is discontinued and the CLI refuses a
journal that has segments and no meta file.
"""

import hashlib
import hmac
import os
import struct

import reference

FORMAT_V2 = 0x02
NONCE_LEN = 24
TAG_LEN = 16
KEY_LEN = 32
AAD_LEN = 29
ENVELOPE_OVERHEAD = 1 + NONCE_LEN + TAG_LEN
PLACEHOLDER_V2 = b"\x00" * ENVELOPE_OVERHEAD
META_MAGIC = b"ZPM1"
KEY_FILE_NAME = b"zephyr.key"
# A fixed fixture master key (not secret: the gates are deterministic).
FIXTURE_KEY = bytes(range(1, 33))


class AuthError(Exception):
    pass


# ---------------------------------------------------------------- ChaCha20

def _rotl(n, k):
    return ((n << k) | (n >> (32 - k))) & 0xFFFFFFFF


def _quarter(s, a, b, c, d):
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF
    s[d] = _rotl(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotl(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF
    s[d] = _rotl(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotl(s[b] ^ s[c], 7)


def _chacha_block(key, counter, nonce12, rounds=20):
    """RFC 8439 section 2.3. No final addition — used by HChaCha20."""
    c = b"expand 32-byte k"
    s = list(struct.unpack("<4I", c) + struct.unpack("<8I", key)
             + (counter,) + struct.unpack("<3I", nonce12))
    working = s[:]
    for _ in range(rounds // 2):
        _quarter(working, 0, 4, 8, 12)
        _quarter(working, 1, 5, 9, 13)
        _quarter(working, 2, 6, 10, 14)
        _quarter(working, 3, 7, 11, 15)
        _quarter(working, 0, 5, 10, 15)
        _quarter(working, 1, 6, 11, 12)
        _quarter(working, 2, 7, 8, 13)
        _quarter(working, 3, 4, 9, 14)
    return working, s


def chacha20_block(key, counter, nonce12):
    working, initial = _chacha_block(key, counter, nonce12)
    added = [(a + b) & 0xFFFFFFFF for a, b in zip(working, initial)]
    return struct.pack("<16I", *added)


def hchacha20(key, nonce16):
    """HChaCha20: 20 rounds, no final addition, words 0-3 and 12-15."""
    working, _ = _chacha_block(key, 0, b"\x00" * 12)
    # Re-run with the 16-byte nonce in the counter+nonce slots.
    c = b"expand 32-byte k"
    words = list(struct.unpack("<4I", c) + struct.unpack("<8I", key)
                 + struct.unpack("<4I", nonce16))
    working = words[:]
    for _ in range(10):
        _quarter(working, 0, 4, 8, 12)
        _quarter(working, 1, 5, 9, 13)
        _quarter(working, 2, 6, 10, 14)
        _quarter(working, 3, 7, 11, 15)
        _quarter(working, 0, 5, 10, 15)
        _quarter(working, 1, 6, 11, 12)
        _quarter(working, 2, 7, 8, 13)
        _quarter(working, 3, 4, 9, 14)
    return struct.pack("<8I", *(working[0:4] + working[12:16]))


def chacha20_xor(key, counter, nonce12, data):
    out = bytearray()
    i = 0
    while i < len(data):
        block = chacha20_block(key, counter, nonce12)
        chunk = data[i:i + 64]
        out += bytes(a ^ b for a, b in zip(chunk, block))
        i += 64
        counter = (counter + 1) & 0xFFFFFFFF
    return bytes(out)


# ---------------------------------------------------------------- Poly1305

P1305 = (1 << 130) - 5


def _clamp(r):
    r &= 0x0ffffffc0ffffffc0ffffffc0fffffff
    return r


def poly1305(key32, msg):
    r = _clamp(int.from_bytes(key32[:16], "little"))
    s = int.from_bytes(key32[16:], "little")
    acc = 0
    for i in range(0, len(msg), 16):
        block = msg[i:i + 16]
        n = int.from_bytes(block + b"\x01", "little")
        acc = (r * (acc + n)) % P1305
    acc = (acc + s) & ((1 << 128) - 1)
    return acc.to_bytes(16, "little")


def _pad16(n):
    return b"\x00" * ((16 - n % 16) % 16)


def aead_encrypt(key, nonce12, aad, plaintext):
    otk = chacha20_xor(key, 0, nonce12, b"\x00" * 32)
    ct = chacha20_xor(key, 1, nonce12, plaintext)
    mac_data = aad + _pad16(len(aad)) + ct + _pad16(len(ct))
    mac_data += struct.pack("<Q", len(aad)) + struct.pack("<Q", len(ct))
    return ct, poly1305(otk, mac_data)


def aead_decrypt(key, nonce12, aad, ct, tag):
    otk = chacha20_xor(key, 0, nonce12, b"\x00" * 32)
    mac_data = aad + _pad16(len(aad)) + ct + _pad16(len(ct))
    mac_data += struct.pack("<Q", len(aad)) + struct.pack("<Q", len(ct))
    if not hmac.compare_digest(poly1305(otk, mac_data), tag):
        raise AuthError("authentication failed")
    return chacha20_xor(key, 1, nonce12, ct)


def xchacha20poly1305_encrypt(key, nonce24, aad, plaintext):
    subkey = hchacha20(key, nonce24[:16])
    subnonce = b"\x00" * 4 + nonce24[16:]
    return aead_encrypt(subkey, subnonce, aad, plaintext)


def xchacha20poly1305_decrypt(key, nonce24, aad, ct, tag):
    subkey = hchacha20(key, nonce24[:16])
    subnonce = b"\x00" * 4 + nonce24[16:]
    return aead_decrypt(subkey, subnonce, aad, ct, tag)


# ---------------------------------------------------------------- envelope

def hkdf_expand(prk, info, length):
    """HKDF-SHA256-Expand (RFC 5869). Zig's std.crypto.kdf.hkdf.HkdfSha256.expand."""
    out = b""
    prev = b""
    counter = 1
    while len(out) < length:
        prev = hmac.new(prk, prev + info + bytes([counter]), hashlib.sha256).digest()
        out += prev
        counter += 1
    return out[:length]


def record_key(master, nonce24):
    return hkdf_expand(master, nonce24, KEY_LEN)


def aad_of(seq, rec):
    """Header prefix [0..29): version, type, seq, timestamp, tz, flags, target."""
    return (
        struct.pack(">BB", 1, reference.TYPE_NUM[rec["type"]])
        + struct.pack(">Q", seq)
        + struct.pack(">Q", rec["timestamp_ms"])
        + struct.pack(">h", rec["tz_offset_min"])
        + struct.pack(">B", 1 if rec["private"] else 0)
        + struct.pack(">Q", rec["target_seq"])
    )


def body_of(rec):
    """The v1 payload body without the 32-byte salt (spec section 2)."""
    return reference.encode_payload(b"\x00" * 32, rec["text"], rec["tags"])[32:]


def seal(master, nonce24, aad, plaintext):
    key = record_key(master, nonce24)
    ct, tag = xchacha20poly1305_encrypt(key, nonce24, aad, plaintext)
    return bytes([FORMAT_V2]) + nonce24 + ct + tag


def open_envelope(master, aad, envelope):
    if len(envelope) < ENVELOPE_OVERHEAD or envelope[0] != FORMAT_V2:
        raise AuthError("not a v2 envelope")
    nonce = envelope[1:1 + NONCE_LEN]
    tag = envelope[-TAG_LEN:]
    ct = envelope[1 + NONCE_LEN:-TAG_LEN]
    return xchacha20poly1305_decrypt(record_key(master, nonce), nonce, aad, ct, tag)


def is_placeholder_v2(payload):
    return payload == PLACEHOLDER_V2


def fixture_nonce(seq):
    """Deterministic nonce for gate fixtures. Unique per seq, not secret."""
    return hashlib.sha256(b"zephyr-fixture-nonce" + struct.pack(">Q", seq)).digest()[:NONCE_LEN]


# ---------------------------------------------------------------- meta

def encode_meta(store, key_id):
    if isinstance(key_id, str):
        key_id = key_id.encode("ascii")
    if not 1 <= len(key_id) <= 255:
        raise ValueError("key_id length")
    return META_MAGIC + bytes([1, store]) + struct.pack(">H", len(key_id)) + key_id


def decode_meta(data):
    if len(data) < 8 or data[:4] != META_MAGIC or data[4] != 1:
        raise ValueError("bad meta")
    n = struct.unpack(">H", data[6:8])[0]
    if len(data) != 8 + n:
        raise ValueError("truncated meta")
    return data[5], data[8:]


# ---------------------------------------------------------------- fixture install

def render_journal_v2(journal, master=FIXTURE_KEY):
    """Like reference.render_journal, but every payload is a v2 envelope.

    The commitment is SHA-256 of the envelope (spec section 2). A redaction
    stores the 41-byte placeholder while the header stays over the original
    envelope (record-format redaction rules, placeholder v2).
    """
    recs = []
    prev = reference.GENESIS
    seq = 0
    for seg in journal["segments"]:
        for rec in seg["records"]:
            reference.validate_record(rec)
            aad = aad_of(seq, rec)
            payload = seal(master, fixture_nonce(seq), aad, body_of(rec))
            commitment = hashlib.sha256(payload).digest()
            # header is the 61-byte prefix plus the record hash (93 bytes),
            # matching reference.build_record; the block is hash ‖ header.
            prefix = reference.header_prefix(seq, rec, commitment)
            record_hash = hashlib.sha256(prefix + prev).digest()
            recs.append({
                "seq": seq, "rec": rec, "header": prefix + record_hash,
                "payload": payload, "record_hash": record_hash,
            })
            prev = record_hash
            seq += 1

    replaced = set()
    for r in recs:
        if r["rec"]["type"] == "redaction":
            t = r["rec"]["target_seq"]
            replaced.add(t)
            for other in recs:
                if other["rec"]["type"] == "amendment" and other["rec"]["target_seq"] == t:
                    replaced.add(other["seq"])

    files = {}
    cursor = 0
    for seg in journal["segments"]:
        count = len(seg["records"])
        blocks = b""
        payloads = b""
        for i in range(count):
            r = recs[cursor + i]
            stored = PLACEHOLDER_V2 if r["seq"] in replaced else r["payload"]
            blocks += r["record_hash"] + r["header"]
            payloads += struct.pack(">I", len(stored)) + stored
        cursor += count
        out = bytearray()
        out += b"ZPH1"
        out += bytes([1, 1 if seg["sealed"] else 0])
        out += struct.pack(">Q", cursor - count)
        out += struct.pack(">Q", count)
        out += struct.pack(">I", 125 * count)
        out += struct.pack(">I", len(payloads))
        out += blocks
        out += payloads
        if seg["sealed"]:
            head = recs[cursor - 1]["record_hash"]
            fhash = hashlib.sha256(
                struct.pack(">QQQ", cursor - count, cursor - 1, count) + head).digest()
            out += struct.pack(">QQQ", cursor - count, cursor - 1, count) + head + fhash
        files[seg["name"]] = bytes(out)
    return files, prev


def install_v2(journal_dir, journal, master=FIXTURE_KEY):
    """Write a born-encrypted journal: segments, zephyr.meta (store 0), zephyr.key 0600."""
    files, head = render_journal_v2(journal, master)
    for name, data in files.items():
        with open(os.path.join(journal_dir, name), "wb") as f:
            f.write(data)
    with open(os.path.join(journal_dir, "zephyr.meta"), "wb") as f:
        f.write(encode_meta(0, KEY_FILE_NAME))
    key_path = os.path.join(journal_dir, "zephyr.key")
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, master)
    finally:
        os.close(fd)
    os.chmod(key_path, 0o600)
    return head


def decode_body(body):
    if len(body) < 3:
        raise ValueError("body truncated")
    tlen = struct.unpack(">H", body[:2])[0]
    if 2 + tlen + 1 > len(body):
        raise ValueError("body truncated")
    text = body[2:2 + tlen].decode("utf-8")
    rest = body[2 + tlen:]
    off = 1
    tags = []
    for _ in range(rest[0]):
        n = rest[off]
        tags.append(rest[off + 1:off + 1 + n].decode("utf-8"))
        off += 1 + n
    return text, tags


def payload_plaintext(prefix, payload, master=FIXTURE_KEY):
    """(text, tags) of a stored v2 payload. A placeholder carries nothing."""
    if is_placeholder_v2(payload):
        return "", []
    body = open_envelope(master, prefix[:AAD_LEN], payload)
    return decode_body(body)


def verify_v2(files, master=FIXTURE_KEY):
    """Pass 1 is the v1 structural check with payload decoding swapped.

    files: list of (name, bytes) in name order, as reference.verify wants.
    Returns (record_count, redacted_count, head).
    """
    # Reuse reference.verify's structure by temporarily decoding envelopes
    # into v1-shaped payloads is not possible (commitments bind the envelope).
    # Duplicate only the payload pass: run reference.verify's chain checks by
    # calling it after swapping... no. Do the payload pass here on top of a
    # structure-only walk that mirrors reference.verify's pass 1.
    headers = []
    file_order = []
    prev = reference.GENESIS
    expected = 0
    for name, data in files:
        if len(data) < 30 or data[:4] != b"ZPH1" or data[4] != 1:
            raise reference.VerifyFailure(name, 0, "file", "not a segment")
        sealed = bool(data[5] & 1)
        start = struct.unpack(">Q", data[6:14])[0]
        count = struct.unpack(">Q", data[14:22])[0]
        hrl = struct.unpack(">I", data[22:26])[0]
        prl = struct.unpack(">I", data[26:30])[0]
        if count == 0 or hrl != 125 * count:
            raise reference.VerifyFailure(name, 0, "file", "inconsistent header")
        if len(data) != 30 + 125 * count + prl + (88 if sealed else 0):
            raise reference.VerifyFailure(name, 0, "file", "size mismatch")
        base = len(headers)
        w = 30 + 125 * count
        for i in range(count):
            block = data[30 + 125 * i:30 + 125 * (i + 1)]
            h = block[32:125]
            if hashlib.sha256(h[:61] + prev).digest() != h[61:93]:
                raise reference.VerifyFailure(name, expected, "record_hash", "chain mismatch")
            if block[:32] != h[61:93]:
                raise reference.VerifyFailure(name, expected, "record_hash", "hash copy differs")
            seq = struct.unpack(">Q", h[2:10])[0]
            if seq != expected:
                raise reference.VerifyFailure(name, seq, "seq", "gap")
            prev = h[61:93]
            expected += 1
            plen = struct.unpack(">I", data[w:w + 4])[0]
            w += 4
            payload = data[w:w + plen]
            w += plen
            headers.append((name, seq, h[1], struct.unpack(">Q", h[21:29])[0], payload, h))
        if w != 30 + 125 * count + prl:
            raise reference.VerifyFailure(name, base, "payload_region", "truncated")
        file_order.append((name, data, sealed, start, count, prev))

    total = len(headers)
    redacted = [False] * total
    for i, (name, seq, rtype, target, payload, h) in enumerate(headers):
        if rtype != 4:
            continue
        if target >= total:
            raise reference.VerifyFailure(name, seq, "target_seq", "redaction target not found")
        redacted[target] = True

    redacted_count = 0
    for i, (name, seq, rtype, target, payload, h) in enumerate(headers):
        target_redacted = target < total and redacted[target]
        is_redacted = (rtype == 1 and redacted[i]) or (rtype == 2 and target_redacted)
        if is_redacted:
            if payload != PLACEHOLDER_V2:
                raise reference.VerifyFailure(name, seq, "payload", "redacted record missing placeholder v2")
            if rtype == 1:
                redacted_count += 1
        else:
            if hashlib.sha256(payload).digest() != h[29:61]:
                raise reference.VerifyFailure(name, seq, "commitment", "payload does not match commitment")
            if rtype in (1, 2) and not is_placeholder_v2(payload):
                try:
                    open_envelope(master, h[:AAD_LEN], payload)
                except AuthError as e:
                    raise reference.VerifyFailure(name, seq, "payload", str(e))
    head = file_order[-1][5] if file_order else reference.GENESIS
    return total, redacted_count, head


# ---------------------------------------------------------------- self-check

# libsodium test/default/xchacha20.c tv_hchacha20, first vector.
_HCHACHA = (
    "24f11cce8a1b3d61e441561a696c1c1b7e173d084fd4812425435a8896a013dc",
    "d9660c5900ae19ddad28d6e06e45fe5e",
    "5966b3eec3bff1189f831f06afe4d4e3be97fa9235ec8c20d08acfbbb4e851e3",
)

# RFC 8439 section 2.8.2 (key, 12-byte nonce = 07 00 00 00 ‖ IV, AAD, plaintext, ciphertext, tag).
_RFC8439_KEY = bytes.fromhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
_RFC8439_NONCE = bytes.fromhex("070000004041424344454647")
_RFC8439_AAD = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
_RFC8439_PT = (b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip "
               b"for the future, sunscreen would be it.")
_RFC8439_CT = bytes.fromhex(
    "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
    "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
    "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
    "3ff4def08e4b7a9de576d26586cec64b6116")
_RFC8439_TAG = bytes.fromhex("1ae10b594f09e26a7e902ecbd0600691")

# RFC 5869 A.1 (extract+expand) — pins expand once the PRK is known.
_HKDF_PRK = bytes.fromhex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
_HKDF_INFO = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
_HKDF_OKM = bytes.fromhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")


def self_check():
    problems = []
    key, nonce, out = (bytes.fromhex(x) for x in _HCHACHA)
    got = hchacha20(key, nonce)
    if got != out:
        problems.append(f"hchacha20: {got.hex()} != {out.hex()}")
    ct, tag = aead_encrypt(_RFC8439_KEY, _RFC8439_NONCE, _RFC8439_AAD, _RFC8439_PT)
    if ct != _RFC8439_CT or tag != _RFC8439_TAG:
        problems.append("rfc 8439 aead vector mismatch")
    if aead_decrypt(_RFC8439_KEY, _RFC8439_NONCE, _RFC8439_AAD, ct, tag) != _RFC8439_PT:
        problems.append("rfc 8439 decrypt mismatch")
    if hkdf_expand(_HKDF_PRK, _HKDF_INFO, 42) != _HKDF_OKM:
        problems.append("hkdf expand mismatch")
    # Envelope round trip under the fixture key.
    master = FIXTURE_KEY
    nonce24 = fixture_nonce(0)
    aad = b"\x01" * AAD_LEN
    env = seal(master, nonce24, aad, b"hello")
    if open_envelope(master, aad, env) != b"hello":
        problems.append("envelope round trip")
    try:
        open_envelope(master, b"\x02" * AAD_LEN, env)
        problems.append("aad swap authenticated")
    except AuthError:
        pass
    return problems


if __name__ == "__main__":
    bad = self_check()
    if bad:
        print("FAIL")
        for b in bad:
            print(" ", b)
        raise SystemExit(1)
    print("ok: hchacha20, rfc8439 aead, hkdf, envelope round trip")
