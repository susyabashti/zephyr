#!/usr/bin/env python3
"""Independent gate for the derived layer (spec/derived.md section 8).

Renders the fixture journal with test/reference.py, runs the real zephyr
CLI as a subprocess, and compares the derived artifacts byte-for-byte
against a Python re-implementation of the ZDI1 index, the digest and
profile renders, and the ask pack — so the format is checked against an
independent implementation, not against the Zig code under test.

Checks:
  - index.zdi is byte-identical to the Python ZDI1 encoding (magic,
    version byte, head, words, entities, SHA-256 footer);
  - profile.md is byte-identical to the Python profile render;
  - the ask pack is byte-identical to the Python pack (provenance line,
    question, profile, notes, period digest, keyword matches, footer);
  - recap serves the Python digest render;
  - rebuild determinism: delete derived/ and profile.md, re-read, and
    the pack and index are byte-identical;
  - staleness: `zephyr log` appends a real entry with a wall-clock
    timestamp; the state is re-derived from the on-disk bytes (no
    guessing the timestamp) and the next read regenerates, matching the
    Python pack for the new journal;
  - notes.md is user-owned and never rewritten by any of this.

Usage:
  python3 test/derivedref.py --check [path-to-zephyr]

The binary defaults to zig-out/bin/zephyr; run `zig build` first.
"""

import hashlib
import os
import re
import shutil
import signal
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import reference

BIN_DEFAULT = os.path.join(HERE, "..", "zig-out", "bin", "zephyr")
WORK_DIR = os.path.join(HERE, "..", ".tmp-derivedref")

BASE = 1_767_225_600_000  # 2026-01-01T00:00:00Z (a Thursday)
DAY0 = 20454             # civil day of 2026-01-01

MAGIC = b"ZDI1"
INDEX_VERSION = 1
MAX_NAME_LEN = 255
PROFILE_HEADER = "# zephyr-profile: v1 "
INDEX_FILE = "derived/index.zdi"
PROFILE_FILE = "profile.md"
NOTES_FILE = "notes.md"
FOOTER = ("Answer using only the entries above; cite seqs; say so if the "
          "answer is not present.\n")
PACK_MATCH_CAP = 8 << 10

# Frozen stoplists (src/core/tokens.zig; version-gated by the index version
# byte — spec/derived.md section 4).
QUESTION_STOPWORDS = {w.lower() for w in """
about after again all along also always among another any anyone anything
are around because been before being below between both but by can cannot
could did does doing done down during each else few for from further get
got had has have having he her here hers him his how however if in into is
it its just may me might more most much must my near no nor not now of off
on once one only onto or other our ours out over own said same saw say says
she should since so some still such than that the their theirs them then
there these they this those through to too under until up upon very was we
were what when where which while who whole whom whose why will with within
without would you your yours
""".split()}

ENTITY_STOPWORDS = {
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    "Sunday", "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

ISSPACE = set(" \t\n\v\f\r")


class AlarmTimeout(Exception):
    pass


def _on_alarm(signum, frame):
    raise AlarmTimeout()


# ---------------------------------------------------------------- fixture

def fixture_journal():
    def rec(seq, rtype, text, tags, offset, private=False, target_seq=0):
        return {
            "type": rtype,
            "text": text,
            "tags": tags,
            "timestamp_ms": BASE + offset,
            "tz_offset_min": 0,
            "private": private,
            "target_seq": target_seq,
            "salt_hex": format(seq, "064x"),
        }

    return {
        "segments": [
            {
                "name": "2026-01.zph",
                "sealed": False,
                "records": [
                    rec(0, "entry", "shipped the auth fix", ["work"], 3_600_000),
                    rec(1, "entry", "reviewed Berlin notes with Alice", [], 7_200_000),
                    rec(2, "entry", "PRIVATE-DERIVED-MARKER-9f2c", ["priv"], 10_800_000, private=True),
                    rec(3, "entry", "walked the dog", [], 14_400_000),
                    rec(4, "redaction", "", [], 18_000_000, target_seq=3),
                    rec(5, "entry", "Zephyr demo for Alice in Berlin", ["work"], (4 * 86_400_000) + 32_400_000),
                    rec(6, "entry", "fixed the deploy pipeline", ["work"], (4 * 86_400_000) + 36_000_000),
                ],
            },
        ],
    }


def write_journal(journal_dir):
    files, head = reference.render_journal(fixture_journal())
    for name, data in files.items():
        with open(os.path.join(journal_dir, name), "wb") as f:
            f.write(data)
    return head


# ---------------------------------------------------------------- tokenizer / view

def spans(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c.isascii() and c.isalpha():
            j = i
            while j < n and text[j].isascii() and text[j].isalpha():
                j += 1
            out.append((i, j))
            i = j
        else:
            i += 1
    return out


def day_of(rec):
    return (rec["timestamp_ms"] + rec["tz_offset_min"] * 60_000) // 86_400_000


def visible_entries(recs):
    """The view rules (record-format section 9): non-private entries that
    are not tombstoned, latest amendment wins, redacted entries carry the
    placeholder (empty text, no tags), each with its local day."""
    redacted, tombstoned = set(), set()
    for seq, rec in recs:
        if rec["type"] == "redaction":
            redacted.add(rec["target_seq"])
        if rec["type"] == "tombstone":
            tombstoned.add(rec["target_seq"])
    effective = {}
    for seq, rec in recs:
        if rec["type"] == "entry":
            effective[seq] = (rec["text"], list(rec["tags"]), False)
        elif rec["type"] == "amendment" and rec["target_seq"] in effective:
            effective[rec["target_seq"]] = (rec["text"], list(rec["tags"]), True)
    out = []
    for seq, rec in recs:
        if rec["type"] != "entry" or rec["private"] or seq in tombstoned:
            continue
        if seq in redacted:
            text, tags, edited = "", [], False
        else:
            text, tags, edited = effective[seq]
        out.append({
            "seq": seq,
            "ts_ms": rec["timestamp_ms"],
            "tz": rec["tz_offset_min"],
            "day": day_of(rec),
            "redacted": seq in redacted,
            "text": text,
            "tags": tags,
        })
    return out


def decode_journal_dir(journal_dir):
    """The records of every on-disk segment, in reader order. The staleness
    check re-derives state this way, so the wall-clock timestamp of an
    appended entry comes from the bytes, not from a guess."""
    recs = []
    seq = 0
    for name in sorted(os.listdir(journal_dir)):
        if not re.fullmatch(r"\d{4}-\d{2}\.zph", name):
            continue
        with open(os.path.join(journal_dir, name), "rb") as f:
            data = f.read()
        if data[:4] != b"ZPH1":
            raise RuntimeError(f"{name}: bad magic")
        count = struct.unpack(">Q", data[14:22])[0]
        block_bytes = struct.unpack(">I", data[22:26])[0]
        blocks = data[30:30 + block_bytes]
        payloads = data[30 + block_bytes:]
        for i in range(count):
            block = blocks[i * 125:(i + 1) * 125]
            prefix = block[32:32 + 61]
            version, rtype = prefix[0], prefix[1]
            rseq = struct.unpack(">Q", prefix[2:10])[0]
            ts = struct.unpack(">Q", prefix[10:18])[0]
            tz = struct.unpack(">h", prefix[18:20])[0]
            flags = prefix[20]
            target = struct.unpack(">Q", prefix[21:29])[0]
            assert version == 1 and rseq == seq, f"{name}: chain gap at {rseq}"
            plen = struct.unpack(">I", payloads[:4])[0]
            payload = payloads[4:4 + plen]
            payloads = payloads[4 + plen:]
            text, tags = "", []
            if rtype in (1, 2):
                body = payload[32:]
                tlen = struct.unpack(">H", body[:2])[0]
                text = body[2:2 + tlen].decode("utf-8")
                rest = body[2 + tlen:]
                off = 1
                for _ in range(rest[0]):
                    tlen2 = rest[off]
                    tags.append(rest[off + 1:off + 1 + tlen2].decode("utf-8"))
                    off += 1 + tlen2
            recs.append((seq, {
                "type": {1: "entry", 2: "amendment", 3: "tombstone",
                         4: "redaction", 5: "checkpoint"}[rtype],
                "text": text,
                "tags": tags,
                "timestamp_ms": ts,
                "tz_offset_min": tz,
                "private": bool(flags & 1),
                "target_seq": target,
            }))
            seq += 1
    return recs


# ---------------------------------------------------------------- derived format

def entry_words(v):
    toks = set()
    for tag in v["tags"]:
        if 2 <= len(tag) <= MAX_NAME_LEN:
            toks.add(tag.lower())
    for a, b in spans(v["text"]):
        w = v["text"][a:b]
        if len(w) >= 2:
            toks.add(w.lower())
    return toks


def build_words(ves):
    m = {}
    for v in ves:
        for w in entry_words(v):
            m.setdefault(w, set()).add(v["seq"])
    return {w: sorted(s) for w, s in sorted(m.items())}


def sentence_start(text, pos):
    if pos == 0:
        return True
    j = pos
    while j > 0 and text[j - 1] in ISSPACE:
        j -= 1
    if j == 0:
        return True
    return text[j - 1] in ".!?"


def word_qualifies(text, a, b):
    w = text[a:b]
    if len(w) < 2:
        return False
    if not (w[0].isascii() and w[0].isupper()):
        return False
    if not any(c.isascii() and c.islower() for c in w):
        return False
    if sentence_start(text, a):
        return False
    return w not in ENTITY_STOPWORDS


def consecutive(text, a1, b1, a2, b2):
    between = text[b1:a2]
    return len(between) > 0 and all(c == " " for c in between)


def phrase_runs(text, sp):
    runs = []
    i = 0
    n = len(sp)
    while i < n:
        if not word_qualifies(text, sp[i][0], sp[i][1]):
            i += 1
            continue
        j = i + 1
        while (j < n and word_qualifies(text, sp[j][0], sp[j][1])
               and consecutive(text, sp[j - 1][0], sp[j - 1][1], sp[j][0], sp[j][1])):
            j += 1
        if j - i <= 4:
            runs.append(text[sp[i][0]:sp[j - 1][1]])
        i = j
    return runs


def build_entities(ves):
    m = {}
    for v in ves:
        for tag in v["tags"]:
            if len(tag) <= MAX_NAME_LEN:
                e = m.setdefault(tag, {"kind": 0, "seqs": set()})
                e["kind"] = 0
                e["seqs"].add(v["seq"])
        for run in phrase_runs(v["text"], spans(v["text"])):
            if len(run) <= MAX_NAME_LEN:
                e = m.setdefault(run, {"kind": 1, "seqs": set()})
                e["seqs"].add(v["seq"])
    out = []
    for name in sorted(m):
        e = m[name]
        seqs = sorted(e["seqs"])
        out.append({"name": name, "kind": e["kind"],
                    "first": seqs[0], "last": seqs[-1], "count": len(seqs)})
    return out


def encode_zdi1(head, record_count, words, entities):
    b = bytearray()
    b += MAGIC
    b += bytes([INDEX_VERSION, 0])
    b += head
    b += struct.pack(">Q", record_count)
    b += struct.pack(">Q", len(words))
    for w, seqs in words.items():
        wb = w.encode("ascii")
        b += bytes([len(wb)]) + wb
        b += struct.pack(">I", len(seqs))
        for s in seqs:
            b += struct.pack(">I", s)
    b += struct.pack(">Q", len(entities))
    for e in entities:
        nb = e["name"].encode("ascii")
        b += bytes([len(nb)]) + nb
        b += bytes([e["kind"]])
        b += struct.pack(">III", e["first"], e["last"], e["count"])
    b += hashlib.sha256(bytes(b)).digest()
    return bytes(b)


def civil_date(day):
    return reference.date_from_epoch_day(day)


def fmt_date(day):
    d = civil_date(day)
    return f"{d.year:04d}-{d.month:02d}-{d.day:02d}"


def render_digest(ves, start, end, head):
    in_range = [v for v in ves if start <= v["day"] < end]
    n = len(in_range)
    red = sum(1 for v in in_range if v["redacted"])
    tags, wc = {}, {}
    for v in in_range:
        if v["redacted"]:
            continue
        for t in v["tags"]:
            tags[t] = tags.get(t, 0) + 1
        for a, b in spans(v["text"]):
            w = v["text"][a:b]
            if len(w) >= 2:
                wc[w.lower()] = wc.get(w.lower(), 0) + 1
    if n == 0:
        seq_range = "0..0"
    else:
        seqs = [v["seq"] for v in in_range]
        seq_range = f"{min(seqs)}..{max(seqs)}"
    out = (f"# zephyr-digest: period={fmt_date(start)}..{fmt_date(end - 1)} "
           f"range=seq {seq_range} head={head.hex()}\n")
    if n == 0:
        out += "0 entries\n"
    else:
        out += f"{n} entries ({red} redacted)\n" if red else f"{n} entries\n"
        if tags:
            items = sorted(tags.items(), key=lambda kv: (-kv[1], kv[0]))
            out += "tags: " + ", ".join(f"{t} {c}" for t, c in items) + "\n"
        if wc:
            items = sorted(wc.items(), key=lambda kv: (-kv[1], kv[0]))[:20]
            out += "top words: " + ", ".join(f"{t} {c}" for t, c in items) + "\n"
    return out


def render_profile(ves, entities, record_count, head):
    n = len(ves)
    if n == 0:
        rng = "none" if record_count == 0 else f"seq 0..{record_count - 1}"
        return f"# zephyr-profile: v1 range={rng} head={head.hex()}\n0 entries\n"
    red = sum(1 for v in ves if v["redacted"])
    months = {}
    for v in ves:
        d = civil_date(v["day"])
        key = d.year * 12 + (d.month - 1)
        months[key] = months.get(key, 0) + 1
    best_key, best_count = min(months.items(), key=lambda kv: (-kv[1], kv[0]))
    by, bm = divmod(best_key, 12)
    first = fmt_date(min(v["day"] for v in ves))
    last = fmt_date(max(v["day"] for v in ves))
    out = f"# zephyr-profile: v1 range=seq 0..{record_count - 1} head={head.hex()}\n"
    out += f"{n} entries, {first}..{last}"
    if red:
        out += f" ({red} redacted)"
    out += "\n"
    out += f"most active: {by:04d}-{bm + 1:02d} ({best_count} entries)\n"
    for kind, label in ((0, "tags"), (1, "people and places")):
        items = [e for e in entities if e["kind"] == kind]
        if not items:
            continue
        items.sort(key=lambda e: (-e["count"], e["name"]))
        out += label + ": " + ", ".join(f"{e['name']} {e['count']}" for e in items[:10]) + "\n"
    return out


def question_words(question):
    out = []
    for a, b in spans(question):
        w = question[a:b]
        if len(w) < 2:
            continue
        lw = w.lower()
        if lw in QUESTION_STOPWORDS:
            continue
        if lw not in out:
            out.append(lw)
    return out


def retrieve(ves, words, question, rng):
    matched = set()
    for w in question_words(question):
        matched.update(words.get(w, ()))
    out = []
    for v in ves:
        if v["redacted"]:
            continue
        if rng and not (rng[0] <= v["day"] < rng[1]):
            continue
        if v["seq"] in matched:
            out.append(v)
    return out


def render_matches(matches, question):
    plural = "" if len(matches) == 1 else "es"
    out = f"# {len(matches)} match{plural} for \"{question}\"\n"
    used = shown = 0
    body = ""
    for m in matches:
        secs = (m["ts_ms"] + m["tz"] * 60_000) // 1000
        line = (f"{m['seq']:04d}  {fmt_date(m['day'])} "
                f"{(secs % 86_400) // 3600:02d}:{(secs % 3600) // 60:02d}  ")
        for t in m["tags"]:
            line += f"[{t}]"
        if m["tags"]:
            line += " "
        line += m["text"] + "\n"
        if shown > 0 and used + len(line) > PACK_MATCH_CAP:
            break
        body += line
        used += len(line)
        shown += 1
    if shown < len(matches):
        body += f"... {len(matches) - shown} more match(es) not shown\n"
    return out + body


def render_pack(head, record_count, ves, question, rng, notes=None):
    prov = f"# zephyr: seq 0..{record_count - 1} head={head.hex()}\n"
    parts = [prov, f"# question: {question}\n"]
    parts.append(render_profile(ves, build_entities(ves), record_count, head))
    if notes is not None:
        sep = "" if notes.endswith("\n") else "\n"
        parts.append(f"# notes\n{notes}{sep}")
    if rng:
        parts.append(render_digest(ves, rng[0], rng[1], head))
    matches = retrieve(ves, build_words(ves), question, rng)
    if matches:
        parts.append(render_matches(matches, question))
    parts.append(FOOTER)
    return "".join(parts)


# ---------------------------------------------------------------- gate

def run_gate(binary):
    problems = []

    def expect(cond, msg):
        if not cond:
            problems.append(msg)

    def expect_bytes(got, want, what):
        if got != want:
            ga, wa = got[:400], want[:400]
            problems.append(f"{what}: bytes differ\n  got:  {ga!r}\n  want: {wa!r}")

    def read(path):
        with open(path, "rb") as f:
            return f.read()

    def run_cli(journal_dir, *args, timeout=30):
        old = signal.signal(signal.SIGALRM, _on_alarm)
        signal.alarm(timeout)
        try:
            p = subprocess.run(
                [binary, "--journal", journal_dir, *args],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old)
        if p.returncode != 0:
            raise RuntimeError(f"zephyr {' '.join(args)}: exit {p.returncode}: "
                               f"{p.stderr.decode('utf-8', 'replace')}")
        return p.stdout

    signal.signal(signal.SIGALRM, _on_alarm)
    try:
        if os.path.exists(WORK_DIR):
            shutil.rmtree(WORK_DIR)
        journal_dir = os.path.join(WORK_DIR, "journal")
        os.makedirs(journal_dir)

        question = "anything about auth or Alice?"
        rng = (DAY0, DAY0 + 5)  # 2026-01-01 .. 2026-01-05 inclusive

        # ---- fixture ------------------------------------------------
        head = write_journal(journal_dir)
        recs = decode_journal_dir(journal_dir)
        ves = visible_entries(recs)
        record_count = len(recs)

        # ask: the full pack, byte-for-byte.
        got = run_cli(journal_dir, "ask", "2026-01-01:2026-01-05",
                      "anything", "about", "auth", "or", "Alice?")
        expect_bytes(got, render_pack(head, record_count, ves, question, rng).encode(),
                     "ask pack")

        # index.zdi: the binary format, byte-for-byte.
        expect_bytes(read(os.path.join(journal_dir, INDEX_FILE)),
                     encode_zdi1(head, record_count, build_words(ves),
                                 build_entities(ves)),
                     "index.zdi")

        # profile.md: the derived profile, byte-for-byte.
        expect_bytes(read(os.path.join(journal_dir, PROFILE_FILE)),
                     render_profile(ves, build_entities(ves), record_count, head).encode(),
                     "profile.md")

        # recap: the digest artifact for an explicit period.
        got = run_cli(journal_dir, "recap", "2026-01-01..2026-01-01")
        expect_bytes(got, render_digest(ves, DAY0, DAY0 + 1, head).encode(),
                     "recap")

        # profile: derived profile plus the one-line no-notes note.
        got = run_cli(journal_dir, "profile")
        expect_bytes(got,
                     (render_profile(ves, build_entities(ves), record_count, head)
                      + "# notes\n(no notes)").encode(),
                     "profile command")

        # ---- notes: user-owned, presented under a heading ------------
        notes = "I live in Berlin.\n"
        with open(os.path.join(journal_dir, NOTES_FILE), "w", encoding="utf-8") as f:
            f.write(notes)
        got = run_cli(journal_dir, "profile")
        expect_bytes(got,
                     (render_profile(ves, build_entities(ves), record_count, head)
                      + f"# notes\n{notes}").encode(),
                     "profile command with notes")
        expect(read(os.path.join(journal_dir, NOTES_FILE)) == notes.encode(),
               "notes.md was rewritten by zephyr profile")

        # ---- rebuild determinism --------------------------------------
        pack_before = got
        index_before = read(os.path.join(journal_dir, INDEX_FILE))
        shutil.rmtree(os.path.join(journal_dir, "derived"))
        os.remove(os.path.join(journal_dir, PROFILE_FILE))
        got = run_cli(journal_dir, "ask", "2026-01-01:2026-01-05",
                      "anything", "about", "auth", "or", "Alice?")
        expect_bytes(got, render_pack(head, record_count, ves, question, rng,
                                      notes).encode(),
                     "ask pack after rebuild")
        expect_bytes(read(os.path.join(journal_dir, INDEX_FILE)), index_before,
                     "index.zdi after rebuild")

        # ---- status ----------------------------------------------------
        got = run_cli(journal_dir, "derived", "status").decode()
        lines = [l for l in got.splitlines() if l]
        # Status lines: `<name>  <state>[ · N records][ · dim D]`.
        expect(any(l.startswith("index  fresh") for l in lines),
               f"derived status: index fresh: {got!r}")
        expect(any(l.startswith("profile  fresh") for l in lines),
               f"derived status: profile fresh: {got!r}")
        expect(any(l.startswith("digest ") and l.endswith("fresh")
                   for l in lines), f"derived status: digest fresh: {got!r}")

        # ---- staleness: a real append, state re-derived from disk ------
        got = run_cli(journal_dir, "log", "-t", "work",
                      "derivedref staleness check")
        expect(b"logged seq 7" in got, f"append: {got!r}")
        # Re-verify the on-disk chain with the reference implementation and
        # take the head from the bytes (the append's timestamp is whatever
        # the wall clock produced; the state is re-derived from disk).
        files = [(name, read(os.path.join(journal_dir, name)))
                 for name in sorted(os.listdir(journal_dir)) if name.endswith(".zph")]
        count2, redacted2, head2 = reference.verify(files)
        recs = decode_journal_dir(journal_dir)
        ves = visible_entries(recs)
        expect(count2 == len(recs), f"record count: disk {len(recs)} vs verify {count2}")
        got = run_cli(journal_dir, "ask", "2026-01-01:2026-01-05",
                      "anything", "about", "auth", "or", "Alice?")
        expect_bytes(got, render_pack(head2, count2, ves, question, rng,
                                      notes).encode(),
                     "ask pack after append (staleness)")
        expect(read(os.path.join(journal_dir, NOTES_FILE)) == notes.encode(),
               "notes.md changed after the append + ask")
    finally:
        signal.alarm(0)

    return problems


# ---------------------------------------------------------------- driver

def main():
    argv = sys.argv[1:]
    if "--check" not in argv:
        print(__doc__)
        return 1
    argv.remove("--check")
    binary = argv[0] if argv else BIN_DEFAULT
    if not os.path.exists(binary):
        print(f"FAIL: binary not found: {binary} (run `zig build` first)")
        return 1
    try:
        problems = run_gate(binary)
    except AlarmTimeout:
        print("FAIL: timed out waiting for zephyr")
        return 1
    except Exception as e:
        print(f"FAIL: gate crashed: {e!r}")
        return 1
    finally:
        if os.path.exists(WORK_DIR):
            shutil.rmtree(WORK_DIR, ignore_errors=True)
    if problems:
        for p in problems:
            print(f"FAIL: {p}")
        return 1
    print("ok: derived layer checks passed (index bytes, profile, pack, recap, "
          "rebuild determinism, staleness)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
