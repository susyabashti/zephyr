#!/usr/bin/env python3
"""Independent reference implementation of the Zephyr v1 byte format.

Implements spec/record-format.md and spec/anchor-format.md using only the
Python standard library (plus test/ed25519.py, a pure-Python Ed25519 per
the RFC 8032 section 6 illustration). It is deliberately independent of
the Zig implementation in src/: the gate is that two implementations
working only from the spec produce byte-identical files, hashes, and
anchor artifacts for the shared vectors in spec/vectors/.

spec/ots-anchor.md is covered by test/otsref.py, a pure-Python
OpenTimestamps v1 proof verifier and legacy Bitcoin block parser, which
validates the OTS vectors in spec/vectors/ots.json.

Usage:
  python3 test/reference.py --gen    fill the expect.* fields in the vectors file
  python3 test/reference.py --check  validate the vectors files end to end
"""

import hashlib
import json
import os
import struct
import sys
import unicodedata
from datetime import date, timedelta

import ed25519
import otsref

EPOCH = date(1970, 1, 1)

def date_from_epoch_day(day):
    return EPOCH + timedelta(days=day)

GENESIS = b"\x00" * 32
PLACEHOLDER = b"\x00" * 35
TYPE_NUM = {"entry": 1, "amendment": 2, "tombstone": 3, "redaction": 4, "checkpoint": 5}
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
VECTORS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "spec", "vectors", "journals.json")
ANCHORS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "spec", "vectors", "anchors.json")


class VerifyFailure(Exception):
    """Carries (file, seq, field, detail) of the first verify failure."""

    def __init__(self, file, seq, field, detail):
        super().__init__(f"{file} seq {seq} {field}: {detail}")
        self.issue = (file, seq, field, detail)


class PayloadDecodeError(Exception):
    """Payload decode failure; the message is the frozen detail string."""


# ---------------------------------------------------------------- text rules

def check_text(b):
    """Spec section 4.1: valid UTF-8, no C0/C1 controls, no combining marks.
    Returns an error detail string or None."""
    i = 0
    n = len(b)
    while i < n:
        c0 = b[i]
        if c0 < 0x80:
            if c0 < 0x20 or c0 == 0x7F:
                return "payload contains a control character"
            i += 1
            continue
        if c0 == 0xC2 and i + 1 < n and 0x80 <= b[i + 1] <= 0x9F:
            return "payload contains a control character"
        if c0 >= 0xF5:
            return "payload is not valid UTF-8"
        length = 2 if c0 < 0xE0 else (3 if c0 < 0xF0 else 4)
        if i + length > n:
            return "payload is not valid UTF-8"
        try:
            ch = b[i:i + length].decode("utf-8")
        except UnicodeDecodeError:
            return "payload is not valid UTF-8"
        if unicodedata.category(ch) in ("Mn", "Mc", "Me"):
            return "payload contains a combining mark"
        i += length
    return None


# ---------------------------------------------------------------- encoding

def encode_payload(salt, text, tags):
    b = bytearray(salt)
    tb = text.encode("utf-8")
    b += struct.pack(">H", len(tb))
    b += tb
    b += bytes([len(tags)])
    for tag in tags:
        gb = tag.encode("utf-8")
        b += bytes([len(gb)]) + gb
    return bytes(b)


def validate_record(rec):
    """Writer-side checks (spec sections 3.1 and 4.1). Raises on violation."""
    rtype = rec["type"]
    text, tags = rec["text"], rec["tags"]
    if check_text(text.encode("utf-8")) is not None:
        raise ValueError(f"{rtype} record: text violates frozen text rules")
    for tag in tags:
        if not 1 <= len(tag.encode("utf-8")) <= 255:
            raise ValueError(f"{rtype} record: tag length out of range")
        if check_text(tag.encode("utf-8")) is not None:
            raise ValueError(f"{rtype} record: tag violates frozen text rules")
    if len(set(tags)) != len(tags):
        raise ValueError(f"{rtype} record: duplicate tag")
    if rtype in ("entry", "amendment"):
        if not text:
            raise ValueError(f"{rtype} record: text must be non-empty")
    else:
        if text or tags:
            raise ValueError(f"{rtype} record: must have empty text and tags")


def header_prefix(seq, rec, commitment):
    return (
        struct.pack(">BB", 1, TYPE_NUM[rec["type"]])
        + struct.pack(">Q", seq)
        + struct.pack(">Q", rec["timestamp_ms"])
        + struct.pack(">h", rec["tz_offset_min"])
        + struct.pack(">B", 1 if rec["private"] else 0)
        + struct.pack(">Q", rec["target_seq"])
        + commitment
    )


def build_record(seq, prev, rec):
    validate_record(rec)
    payload = encode_payload(bytes.fromhex(rec["salt_hex"]), rec["text"], rec["tags"])
    commitment = hashlib.sha256(payload).digest()
    prefix = header_prefix(seq, rec, commitment)
    assert len(prefix) == 61
    record_hash = hashlib.sha256(prefix + prev).digest()
    return prefix + record_hash, payload, record_hash


def render_journal(journal):
    """Renders all segment files of a journal. Returns (files, head).

    A redaction replaces the payload bytes of its target entry and of every
    amendment on that entry with the 35-byte placeholder; headers are
    computed from the original payloads (spec sections 3 and 4).
    """
    recs = []
    prev = GENESIS
    seq = 0
    for seg in journal["segments"]:
        for rec in seg["records"]:
            validate_record(rec)
            header, payload, record_hash = build_record(seq, prev, rec)
            recs.append({
                "seq": seq,
                "rec": rec,
                "header": header,
                "payload": payload,
                "record_hash": record_hash,
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
            stored = PLACEHOLDER if r["seq"] in replaced else r["payload"]
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
            last = cursor - 1
            head = recs[cursor - 1]["record_hash"]
            fhash = hashlib.sha256(struct.pack(">QQQ", cursor - count, last, count) + head).digest()
            out += struct.pack(">QQQ", cursor - count, last, count) + head + fhash
        files[seg["name"]] = bytes(out)
    return files, prev


# ---------------------------------------------------------------- verify

def decode_payload_or_fail(payload):
    """Returns (text, tags) or raises VerifyFailure-style detail string."""
    if len(payload) < 35:
        raise PayloadDecodeError("payload truncated")
    text_len = struct.unpack(">H", payload[32:34])[0]
    text_end = 34 + text_len
    if text_end + 1 > len(payload):
        raise PayloadDecodeError("payload truncated")
    text = payload[34:text_end]
    tag_count = payload[text_end]
    w = text_end + 1
    tags = []
    for _ in range(tag_count):
        if w >= len(payload):
            raise PayloadDecodeError("payload truncated")
        tag_len = payload[w]
        if tag_len == 0:
            raise PayloadDecodeError("tag with zero length")
        w += 1
        if w + tag_len > len(payload):
            raise PayloadDecodeError("payload truncated")
        tag = payload[w:w + tag_len]
        detail = check_text(tag)
        if detail is not None:
            raise PayloadDecodeError(detail)
        if tag in tags:
            raise PayloadDecodeError("duplicate tag")
        tags.append(tag)
        w += tag_len
    if w != len(payload):
        raise PayloadDecodeError("payload truncated")
    detail = check_text(text)
    if detail is not None:
        raise PayloadDecodeError(detail)
    return text, tags


def verify(files):
    """Two-pass verify (spec section 8). files: list of (name, bytes) in name
    order. Returns (record_count, redacted_count, head) or raises
    VerifyFailure with (file, seq, field, detail)."""
    headers = []     # per record: (file, seq, type, target, payload)
    file_order = []  # (name, data, sealed, start, count, last_record_hash)
    prev = GENESIS
    expected_seq = 0

    for name, data in files:
        if len(data) < 30:
            raise VerifyFailure(name, 0, "file", "file is truncated")
        if data[0:4] != b"ZPH1":
            raise VerifyFailure(name, 0, "magic", "bad magic")
        if data[4] != 1:
            raise VerifyFailure(name, 0, "version", "unsupported version")
        if data[5] & 0xFE:
            raise VerifyFailure(name, 0, "flags", "reserved flag bit set")
        sealed = bool(data[5] & 1)
        start = struct.unpack(">Q", data[6:14])[0]
        count = struct.unpack(">Q", data[14:22])[0]
        hrl = struct.unpack(">I", data[22:26])[0]
        prl = struct.unpack(">I", data[26:30])[0]
        if count == 0:
            raise VerifyFailure(name, 0, "record_count", "segment has no records")
        if hrl != 125 * count:
            raise VerifyFailure(name, 0, "header_region_len", "header region length inconsistent")
        total = 30 + 125 * count + prl + (88 if sealed else 0)
        if len(data) != total:
            raise VerifyFailure(name, 0, "file", "file size inconsistent with header")

        base = len(headers)
        for i in range(count):
            block = data[30 + 125 * i:30 + 125 * (i + 1)]
            h = block[32:125]
            if h[0] != 1:
                raise VerifyFailure(name, base + i, "version", "unsupported version")
            if h[1] not in (1, 2, 3, 4, 5):
                raise VerifyFailure(name, base + i, "header", "record header invalid")
            tz = struct.unpack(">h", h[18:20])[0]
            if not -840 <= tz <= 840:
                raise VerifyFailure(name, base + i, "tz_offset_min", "tz offset out of range")
            if h[20] & 0xFE:
                raise VerifyFailure(name, base + i, "flags", "reserved flag bit set")
            if block[0:32] != h[61:93]:
                raise VerifyFailure(name, base + i, "record_hash", "stored record_hash copy differs from header")
            if hashlib.sha256(h[0:61] + prev).digest() != h[61:93]:
                raise VerifyFailure(name, struct.unpack(">Q", h[2:10])[0], "record_hash", "chain mismatch")
            seq = struct.unpack(">Q", h[2:10])[0]
            if seq != expected_seq:
                raise VerifyFailure(name, seq, "seq", f"expected seq {expected_seq}")
            prev = h[61:93]
            expected_seq += 1

        # Payload region.
        w = 30 + 125 * count
        for i in range(count):
            plen = struct.unpack(">I", data[w:w + 4])[0]
            w += 4
            if w + plen > 30 + 125 * count + prl:
                raise VerifyFailure(name, base + i, "payload_region", "payload region truncated")
            payload = data[w:w + plen]
            w += plen
            h = data[30 + 125 * i + 32:30 + 125 * (i + 1)]
            headers.append((name, struct.unpack(">Q", h[2:10])[0], h[1], struct.unpack(">Q", h[21:29])[0], payload, h))
        if w != 30 + 125 * count + prl:
            raise VerifyFailure(name, base, "payload_region", "payload region truncated")
        file_order.append((name, data, sealed, start, count, prev))

    total = len(headers)
    if total == 0:
        return 0, 0, GENESIS

    types = [h[2] for h in headers]
    targets = [h[3] for h in headers]
    is_entry = [t == 1 for t in types]
    file_of = [h[0] for h in headers]

    # Pass 2a: redaction set.
    redacted = [False] * total
    for i in range(total):
        if types[i] != 4:
            continue
        t = targets[i]
        if t >= total:
            raise VerifyFailure(file_of[i], i, "target_seq", "redaction target not found")
        if redacted[t]:
            raise VerifyFailure(file_of[i], t, "redaction", "duplicate redaction of entry")
        redacted[t] = True

    # Pass 2b: payloads.
    redacted_count = 0
    for i, (name, seq, rtype, target, payload, h) in enumerate(headers):
        try:
            decode_payload_or_fail(payload)
        except PayloadDecodeError as e:
            raise VerifyFailure(name, seq, "payload", str(e))
        target_redacted = target < total and redacted[target]
        is_redacted_record = (rtype == 1 and redacted[i]) or (rtype == 2 and target_redacted)
        if is_redacted_record:
            if payload != PLACEHOLDER:
                raise VerifyFailure(name, seq, "payload", "redacted record does not carry the placeholder payload")
            if rtype == 1:
                redacted_count += 1
        else:
            if hashlib.sha256(payload).digest() != h[29:61]:
                raise VerifyFailure(name, seq, "commitment", "payload does not match commitment")

    # Pass 2c: targets.
    for i in range(total):
        if types[i] in (1, 5):
            continue
        t = targets[i]
        if t >= total:
            raise VerifyFailure(file_of[i], i, "target_seq", "target not found")
        if t >= i:
            raise VerifyFailure(file_of[i], i, "target_seq", "target is not earlier than the record")
        if not is_entry[t]:
            raise VerifyFailure(file_of[i], i, "target_seq", "target is not an entry")

    # Pass 2d: sealed footers.
    for name, data, sealed, start, count, head in file_order:
        if not sealed:
            continue
        f = data[-88:]
        first, last, cnt = struct.unpack(">QQQ", f[0:24])
        fhead, fhash = f[24:56], f[56:88]
        if first != start or cnt != count or last != start + count - 1:
            raise VerifyFailure(name, first, "footer", "footer fields do not match the segment")
        if fhead != head:
            raise VerifyFailure(name, last, "footer", "footer head does not match the final record_hash")
        if hashlib.sha256(f[0:56]).digest() != fhash:
            raise VerifyFailure(name, first, "footer", "footer hash mismatch")

    return total, redacted_count, file_order[-1][5]


# ---------------------------------------------------------------- LLM view

def local_ms(ts_ms, tz_offset_min):
    return ts_ms + tz_offset_min * 60_000


def civil_date_from_ms(ts_ms, tz_offset_min):
    lm = local_ms(ts_ms, tz_offset_min)
    day = lm // 86_400_000
    secs = lm // 1000
    return day, date_from_epoch_day(day), (secs // 3600) % 24, (secs // 60) % 60


def render_view(journal, head):
    """Spec section 9. Returns the exact output string ("" for an empty
    journal). The head is no longer part of the view (Phase B); the parameter
    is kept for the call sites."""
    recs = []
    seq = 0
    for seg in journal["segments"]:
        for rec in seg["records"]:
            recs.append((seq, rec))
            seq += 1
    if not recs:
        return ""

    # Redaction and tombstone sets.
    redacted_entries = set()
    tombstoned = set()
    for seq, rec in recs:
        if rec["type"] == "redaction":
            redacted_entries.add(rec["target_seq"])
        if rec["type"] == "tombstone":
            tombstoned.add(rec["target_seq"])

    # Effective text/tags per entry: latest amendment wins (records are in seq order).
    effective = {}
    for seq, rec in recs:
        if rec["type"] == "entry":
            effective[seq] = (rec["text"], rec["tags"], False)
        elif rec["type"] == "amendment" and rec["target_seq"] in effective:
            effective[rec["target_seq"]] = (rec["text"], rec["tags"], True)

    lines = []
    for seq, rec in recs:
        if rec["type"] != "entry":
            continue
        if rec["private"] or seq in tombstoned:
            continue
        day, _, hh, mm = civil_date_from_ms(rec["timestamp_ms"], rec["tz_offset_min"])
        if seq in redacted_entries:
            lines.append((day, rec["timestamp_ms"], seq, f"{hh:02d}:{mm:02d} [redacted]"))
            continue
        text, tags, edited = effective[seq]
        line = f"{hh:02d}:{mm:02d}"
        if edited:
            line += " (edited)"
        if tags:
            line += " " + "".join(f"[{t}]" for t in tags)
        line += " " + text
        lines.append((day, rec["timestamp_ms"], seq, line))
    lines.sort(key=lambda x: (x[0], x[1], x[2]))

    out = []
    current_day = None
    for day, _, seq, line in lines:
        if day != current_day:
            if current_day is not None:
                out.append("")
            d = date_from_epoch_day(day)
            out.append(f"{d.year:04d}-{d.month:02d}-{d.day:02d} {WEEKDAYS[d.weekday()]}")
            current_day = day
        out.append(f"  {seq}  {line}")
    if not out:
        return ""
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- driver

def load_vectors():
    with open(VECTORS_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def apply_corruption(data, corruption):
    data = bytearray(data)
    offset = corruption["offset"]
    if corruption.get("xor") is not None:
        data[offset] ^= corruption["xor"]
    else:
        data[offset] = corruption["value"]
    return bytes(data)


# ---------------------------------------------------------------- anchors

def anchor_message(head, count, timestamp_ms):
    """The 48-byte signed message (anchor-format section 4)."""
    return head + count.to_bytes(8, "big") + timestamp_ms.to_bytes(8, "big")


def build_anchor_artifact(seed, head, count, timestamp_ms, checkpoint_seq):
    """Rebuilds the 190-byte artifact (anchor-format section 3)."""
    public_key = ed25519.secret_to_public(seed)
    signature = ed25519.sign(seed, anchor_message(head, count, timestamp_ms))
    prefix = (b"ZPA1" + b"\x01" + b"\x00"
              + public_key + head
              + count.to_bytes(8, "big") + timestamp_ms.to_bytes(8, "big")
              + checkpoint_seq.to_bytes(8, "big")
              + signature)
    assert len(prefix) == 158
    return prefix + hashlib.sha256(prefix).digest()


def check_anchors():
    """Re-derives every value in spec/vectors/anchors.json independently.
    Returns (problems, count)."""
    with open(ANCHORS_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    if data.get("format_version") != 1:
        return ["anchors: unsupported format_version"], 0
    problems = []
    count = 0
    for ka in data.get("ed25519_known_answer", []):
        seed = bytes.fromhex(ka["seed_hex"])
        message = bytes.fromhex(ka["message_hex"])
        public_key = bytes.fromhex(ka["public_key_hex"])
        signature = bytes.fromhex(ka["signature_hex"])
        if ed25519.secret_to_public(seed) != public_key:
            problems.append(f"anchors {ka['id']}: derived public key differs from the RFC vector")
        if ed25519.sign(seed, message) != signature:
            problems.append(f"anchors {ka['id']}: derived signature differs from the RFC vector")
        if not ed25519.verify(public_key, message, signature):
            problems.append(f"anchors {ka['id']}: signature does not verify")
        count += 1
    for a in data.get("anchors", []):
        seed = bytes.fromhex(a["seed_hex"])
        head = bytes.fromhex(a["head_hex"])
        expect = a["expect"]
        artifact = build_anchor_artifact(seed, head, a["count"], a["timestamp_ms"], a["checkpoint_seq"])
        if ed25519.secret_to_public(seed) != bytes.fromhex(expect["public_key_hex"]):
            problems.append(f"anchors {a['id']}: derived public key differs from the pinned vector")
        if artifact[94:158] != bytes.fromhex(expect["signature_hex"]):
            problems.append(f"anchors {a['id']}: derived signature differs from the pinned vector")
        if artifact.hex() != expect["artifact_hex"].lower():
            problems.append(f"anchors {a['id']}: derived artifact differs from the pinned vector")
        # The self-verification path must reject the corruptions below.
        bad = bytearray(artifact)
        bad[100] ^= 1  # a signature byte; the hash covers it
        if hashlib.sha256(bytes(bad[:158])).digest() == bytes(bad[158:]):
            problems.append(f"anchors {a['id']}: flipped signature byte passed the artifact hash check")
        bad[100] ^= 1  # restore
        bad[120] ^= 1  # another signature byte, with the hash recomputed
        bad[158:] = hashlib.sha256(bytes(bad[:158])).digest()
        message = anchor_message(head, a["count"], a["timestamp_ms"])
        if ed25519.verify(bytes.fromhex(expect["public_key_hex"]), message, bytes(bad[94:158])):
            problems.append(f"anchors {a['id']}: flipped signature byte passed Ed25519 verification")
        bad = bytearray(artifact)
        bad[40] ^= 1  # a head byte; the hash covers it
        if hashlib.sha256(bytes(bad[:158])).digest() == bytes(bad[158:]):
            problems.append(f"anchors {a['id']}: flipped head byte passed the artifact hash check")
        count += 1
    return problems, count


def check_journal(journal, strict):
    """Renders the journal, verifies it, and checks all pinned expectations.
    With strict=False, returns the computed values instead of comparing."""
    files, head = render_journal(journal)
    ordered = sorted(files.items())
    count, redacted, vhead = verify(ordered)
    assert vhead == head
    view = render_view(journal, head)

    if not strict:
        computed_corruptions = []
        for c in journal.get("corruptions", []):
            data = apply_corruption(files[c["segment"]], c)
            modified = [(n, d if n != c["segment"] else data) for n, d in ordered]
            try:
                verify(modified)
                computed_corruptions.append(None)
            except VerifyFailure as e:
                computed_corruptions.append(e.issue)
        return {
            "view": view,
            "segments": [
                {"name": name, "hex": data.hex()} for name, data in sorted(files.items())
            ],
            "footer_hashes": [
                {"name": name, "hash": data[-32:].hex()}
                for name, data in sorted(files.items())
                if data[5] & 1
            ],
            "corruptions": computed_corruptions,
        }

    expect = journal["expect"]
    problems = []
    expect_segments = {e["name"]: e["hex"] for e in expect["segments"]}
    for name, data in files.items():
        if expect_segments.get(name) != data.hex():
            problems.append(f"{journal['id']}: segment {name} hex mismatch")
    if expect["view"] != view:
        problems.append(f"{journal['id']}: view mismatch")
    for e in expect.get("footer_hashes", []):
        if files[e["name"]][-32:].hex() != e["hash"]:
            problems.append(f"{journal['id']}: footer hash mismatch for {e['name']}")
    for i, corruption in enumerate(journal.get("corruptions", [])):
        name = corruption["segment"]
        data = apply_corruption(files[name], corruption)
        modified = [(n, d if n != name else data) for n, d in ordered]
        try:
            verify(modified)
            problems.append(f"{journal['id']}: corruption {i} ({corruption['description']}) did not fail")
            continue
        except VerifyFailure as e:
            got = e.issue
            want = corruption["expect"]
            want_issue = (want["file"], want["seq"], want["field"], want["detail"])
            if got != want_issue:
                problems.append(
                    f"{journal['id']}: corruption {i} ({corruption['description']}) reported {got}, want {want_issue}"
                )
    return problems



def main():
    args = [a for a in sys.argv[1:] if a.startswith("--")]
    if not args:
        print(__doc__)
        sys.exit(2)
    data = load_vectors()
    if data.get("format_version") != 1:
        print("unsupported format_version", file=sys.stderr)
        sys.exit(1)

    if "--gen" in args:
        for journal in data["journals"]:
            computed = check_journal(journal, strict=False)
            journal["expect"]["view"] = computed["view"]
            journal["expect"]["segments"] = computed["segments"]
            journal["expect"]["footer_hashes"] = computed["footer_hashes"]
            for c, computed_c in zip(journal.get("corruptions", []), computed["corruptions"]):
                if computed_c is None:
                    print(f"{journal['id']}: corruption at offset {c['offset']} did not fail verify", file=sys.stderr)
                    sys.exit(1)
                want = c["expect"]
                if (want["file"], want["seq"], want["field"], want["detail"]) != tuple(computed_c):
                    print(f"{journal['id']}: corruption at offset {c['offset']} reports {computed_c}", file=sys.stderr)
                    print(f"  but vectors pin {want}", file=sys.stderr)
                    sys.exit(1)
        with open(VECTORS_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"generated expect fields for {len(data['journals'])} journal(s)")
        return

    if "--check" in args:
        problems = []
        for journal in data["journals"]:
            problems += check_journal(journal, strict=True)
        anchor_problems, n_anchors = check_anchors()
        problems += anchor_problems
        ots_problems, n_ots, n_ots_corr = otsref.check_ots()
        problems += ots_problems
        if problems:
            for p in problems:
                print("FAIL:", p, file=sys.stderr)
            sys.exit(1)
        n_corruptions = sum(len(j.get("corruptions", [])) for j in data["journals"])
        print(f"ok: {len(data['journals'])} journal(s), {n_corruptions} corruption(s), "
              f"{n_anchors} anchor vector(s), {n_ots} OTS vector(s) ({n_ots_corr} OTS corruption checks) all verified")


if __name__ == "__main__":
    main()
