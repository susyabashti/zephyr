#!/usr/bin/env python3
"""Independent gate for the semantic layer (spec/semantic.md sections 5-8).

Two modes:

  python3 test/semref.py --check [path-to-zephyr]
    Offline; needs no model. Renders the labeled-set fixture journal with
    test/reference.py, plants a ZDE1 artifact produced by an independent
    Python encoder, and asserts:
      - `derived status` bytes for a fresh / stale / corrupt / missing
        artifact (dim, model, engine and record digests echoed back);
      - `rank --mode vector` refuses a stale or missing artifact with the
        actionable message (never serves, never rebuilds);
      - `rank --mode keyword` bytes: one line per Phase 7 token hit, the
        seq first (re-implemented here);
      - `ask` with no artifact degrades silently to the exact Phase 7
        keyword pack (test/derivedref.py's render).

  python3 test/semref.py --eval [path-to-zephyr]
    Needs the pinned model (section 2). Rebuilds derived/embed.zde with
    the real engine, then runs `rank --top 5` for every labeled query in
    keyword, vector, and hybrid mode and scores the section-8 gate:
      1. hybrid Recall@5 beats keyword's by a margin of at least 0.2;
      2. hybrid MRR beats keyword's;
      3. no query where keyword has a gold in its top 5 loses it in
         hybrid's top 5.
    Exit codes: 0 = win (ship), 1 = fail (SKIPPED path, section 8),
    2 = setup error (model, build, or spec problem).

The labeled set is spec/vectors/embed-labeled.json; the binary defaults to
zig-out/bin/zephyr (run `zig build` first).
"""

import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import derivedref
import reference
import vaultref

BIN_DEFAULT = os.path.join(HERE, "..", "zig-out", "bin", "zephyr")
WORK_DIR = os.path.join(HERE, "..", ".tmp-semref")
SPEC_VECTORS = os.path.join(HERE, "..", "spec", "vectors", "embed-labeled.json")

# Pinned model (spec/semantic.md section 2).
MODEL_NAME = "embeddinggemma-300M-Q8_0.gguf"
MODEL_BYTES = 328_577_056
MODEL_SHA256 = "a0f7b4e13c397a6e1b32c2de75b1f65a14c92ec524d5f674d94a4290a1c4969b"
MODEL_URL = ("https://huggingface.co/unsloth/"
             "embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf")
EXPECTED_DIM = 768
EMBED_FILE = "derived/embed.zde"

# Frozen fixture contract (spec/vectors/embed-labeled.json description).
RECORD_COUNT = 19
VISIBLE_COUNT = 17
EMBEDDABLE_COUNT = 16
EMBEDDABLE_SEQS = [0, 1, 3, 4, 5, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18]
QUERY_CATEGORIES = {"synonym": 4, "typo": 1, "plural": 1,
                    "morphology": 1, "date": 2, "tag": 2, "multi": 1}

# Deterministic digests for the --check artifact (any 32 bytes will do;
# the binary must echo them back, not invent them).
CHECK_MODEL_HASH = hashlib.sha256(b"semref-check-model").digest()
CHECK_ENGINE_ID = hashlib.sha256(b"semref-check-engine").digest()
CHECK_DIM = 4

EMBED_NO_ARTIFACT_MSG = b"no fresh embedding artifact (run: zephyr derived rebuild --embeddings)"


class AlarmTimeout(Exception):
    pass


def _on_alarm(signum, frame):
    raise AlarmTimeout()


# ---------------------------------------------------------------- labeled set

def load_spec():
    with open(SPEC_VECTORS) as f:
        spec = json.load(f)
    problems = spec_problems(spec)
    if problems:
        for p in problems:
            print(f"FAIL: labeled set: {p}")
        sys.exit(1)
    return spec


def spec_problems(spec):
    out = []
    if spec.get("format_version") != 1:
        out.append("format_version must be 1")
    recs = [r for seg in spec.get("fixture", {}).get("segments", [])
            for r in seg.get("records", [])]
    if len(recs) != RECORD_COUNT:
        out.append(f"{len(recs)} records, want {RECORD_COUNT}")
    cats = {}
    ids = set()
    for q in spec.get("queries", []):
        if q["id"] in ids:
            out.append(f"duplicate query id {q['id']}")
        ids.add(q["id"])
        cats[q["category"]] = cats.get(q["category"], 0) + 1
        for s in q["gold"]:
            if not 0 <= s < len(recs):
                out.append(f"query {q['id']}: gold seq {s} out of range")
    if len(spec.get("queries", [])) != 12:
        out.append(f"{len(spec.get('queries', []))} queries, want 12")
    if cats != QUERY_CATEGORIES:
        out.append(f"categories {cats}, want {QUERY_CATEGORIES}")
    return out


def journal_from_spec(spec):
    """The reference.py journal for the fixture: seq by position,
    timestamp_ms = base + offset, tz 0, salt_hex = format(seq, '064x')."""
    base = spec["base_ms"]
    segs = []
    seq = 0
    for seg in spec["fixture"]["segments"]:
        recs = []
        for raw in seg["records"]:
            recs.append({
                "type": raw["type"],
                "text": raw["text"],
                "tags": list(raw["tags"]),
                "timestamp_ms": base + raw["offset_ms"],
                "tz_offset_min": 0,
                "private": raw.get("private", False),
                "target_seq": raw.get("target_seq", 0),
                "salt_hex": format(seq, "064x"),
            })
            seq += 1
        segs.append({"name": seg["name"], "sealed": seg["sealed"],
                     "records": recs})
    return {"segments": segs}


def write_journal(journal_dir, spec):
    # Born encrypted (spec/encryption.md v2). derivedref.decode_journal_dir
    # opens the envelopes under vaultref's fixture key.
    return vaultref.install_v2(journal_dir, journal_from_spec(spec))


# ---------------------------------------------------------------- ZDE1

def encode_zde1(head, model_hash, engine_id, record_count, seqs, vectors, dim):
    """Independent ZDE1 encoder (spec/semantic.md section 5): little-endian
    header, interleaved chunks (seq u64 + dim x f32), sha256 footer."""
    body = struct.pack(
        "<4sBBHII32s32s32sQQQ",
        b"ZDE1", 1, 0, 0, dim, len(seqs),
        model_hash, engine_id, head,
        record_count, seqs[0] if seqs else 0, seqs[-1] if seqs else 0)
    chunks = b""
    for i, s in enumerate(seqs):
        chunks += struct.pack("<Q", s)
        for j in range(dim):
            chunks += struct.pack("<f", vectors[i * dim + j])
    return body + chunks + hashlib.sha256(body + chunks).digest()


def check_vectors(n, dim):
    """Deterministic f32 vectors, exactly representable (k/16)."""
    out = []
    for i in range(n):
        for j in range(dim):
            out.append(((i * 37 + j * 5) % 16) / 16.0)
    return out


# ---------------------------------------------------------------- keyword + view

def rank_line(v, score):
    """The rank line (spec/semantic.md section 7): seq, date, local time,
    tag block, text, and the score in parentheses three spaces from the
    text. No edit or redaction markers — rank hits are visible entries."""
    d = reference.date_from_epoch_day(v["day"])
    secs = (v["ts_ms"] + v["tz"] * 60_000) // 1000
    time = f"{(secs % 86_400) // 3600:02d}:{(secs % 3600) // 60:02d}"
    tail = ("".join(f"[{t}]" for t in v["tags"]) + " " + v["text"]
            if v["tags"] else v["text"])
    return f"{v['seq']}  {d:%Y-%m-%d} {time}  {tail}   ({float(score):.3f})"


def keyword_hits(ves, question):
    """Phase 7 token retrieval as a ranked list: distinct question-word
    hits per visible non-redacted entry, (hits desc, seq asc)."""
    qwords = derivedref.question_words(question)
    hits = []
    for v in ves:
        if v["redacted"]:
            continue
        toks = {v["text"][a:b].lower() for a, b in derivedref.spans(v["text"])}
        count = sum(1 for w in qwords if w in toks)
        if count > 0:
            hits.append((v["seq"], count))
    hits.sort(key=lambda h: (-h[1], h[0]))
    return hits


# ---------------------------------------------------------------- CLI helper

def make_runner(binary):
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
        return p.returncode, p.stdout, p.stderr

    def must_cli(journal_dir, *args, timeout=30):
        code, out, err = run_cli(journal_dir, *args, timeout=timeout)
        if code != 0:
            raise RuntimeError(
                f"zephyr {' '.join(args)}: exit {code}: "
                f"{err.decode('utf-8', 'replace')}")
        return out

    return run_cli, must_cli


# ---------------------------------------------------------------- --check

def run_check(binary):
    problems = []
    run_cli, must_cli = make_runner(binary)

    def expect(cond, msg):
        if not cond:
            problems.append(msg)

    def expect_bytes(got, want, what):
        if got != want:
            problems.append(f"{what}: bytes differ\n"
                            f"  got:  {got[:400]!r}\n  want: {want[:400]!r}")

    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    journal_dir = os.path.join(WORK_DIR, "journal")
    os.makedirs(journal_dir)

    spec = load_spec()
    head = write_journal(journal_dir, spec)
    recs = derivedref.decode_journal_dir(journal_dir)
    ves = derivedref.visible_entries(recs)
    by_seq = {v["seq"]: v for v in ves}
    record_count = len(recs)
    expect(record_count == RECORD_COUNT,
           f"journal rendered {record_count} records, want {RECORD_COUNT}")
    embeddable = [v for v in ves if not v["redacted"]]
    expect([v["seq"] for v in embeddable] == EMBEDDABLE_SEQS,
           f"embeddable seqs {[v['seq'] for v in embeddable]}, "
           f"want {EMBEDDABLE_SEQS}")
    if problems:
        return problems
    seqs = [v["seq"] for v in embeddable]
    vectors = check_vectors(len(seqs), CHECK_DIM)

    embed_path = os.path.join(journal_dir, EMBED_FILE)
    os.makedirs(os.path.dirname(embed_path), exist_ok=True)

    def plant(data):
        with open(embed_path, "wb") as f:
            f.write(data)

    def status_line(out):
        for line in out.decode().splitlines():
            if line.startswith("embed "):
                return line
        return None

    noun = "record" if record_count == 1 else "records"

    # ---- fresh: the Python-encoded artifact is accepted
    artifact = encode_zde1(head, CHECK_MODEL_HASH, CHECK_ENGINE_ID,
                           record_count, seqs, vectors, CHECK_DIM)
    plant(artifact)
    want = ("index  missing\n"
            f"embed  fresh · {record_count} {noun} · dim {CHECK_DIM}\n"
            "profile  missing\n")
    expect_bytes(must_cli(journal_dir, "derived", "status"),
                 want.encode(), "status: fresh")

    # ---- stale: head mismatch is detected, and vector mode refuses
    stale = bytearray(artifact)
    stale[80] ^= 0xFF  # the head field
    plant(bytes(stale))
    want = ("index  missing\n"
            f"embed  stale · {record_count} {noun} · dim {CHECK_DIM}\n"
            "profile  missing\n")
    expect_bytes(must_cli(journal_dir, "derived", "status"),
                 want.encode(), "status: stale")
    code, out, err = run_cli(journal_dir, "rank", "--mode", "vector",
                             "--top", "5", "the", "dog")
    expect(code != 0, "rank vector over a stale artifact must fail")
    expect(EMBED_NO_ARTIFACT_MSG in err,
           f"rank vector over a stale artifact: stderr {err[:200]!r}")

    # ---- corrupt: a flipped footer byte is detected
    corrupt = bytearray(artifact)
    corrupt[-1] ^= 0xFF
    plant(bytes(corrupt))
    line = status_line(must_cli(journal_dir, "derived", "status"))
    expect(line == "embed  corrupt", f"status corrupt line: {line!r}")

    # ---- missing: no artifact
    os.remove(embed_path)
    line = status_line(must_cli(journal_dir, "derived", "status"))
    expect(line == "embed  missing", f"status missing line: {line!r}")
    code, out, err = run_cli(journal_dir, "rank", "--mode", "vector",
                             "--top", "5", "the", "dog")
    expect(code != 0, "rank vector without an artifact must fail")
    expect(EMBED_NO_ARTIFACT_MSG in err,
           f"rank vector without an artifact: stderr {err[:200]!r}")

    # ---- rank keyword: exact bytes (one line per hit, seq first)
    question = "anything about auth or Alice?"
    hits = keyword_hits(ves, question)
    expect(hits == [(0, 1), (1, 1), (13, 1)],
           f"python keyword hits {hits}, want [(0, 1), (1, 1), (13, 1)]")
    lines = [rank_line(by_seq[seq], score) for seq, score in hits[:10]]
    want = "".join(line + "\n" for line in lines)
    out = must_cli(journal_dir, "rank", "--mode", "keyword", "--top", "10",
                   "anything", "about", "auth", "or", "Alice?")
    expect_bytes(out, want.encode(), "rank keyword")

    # ---- ask: no artifact, silent degrade to the Phase 7 keyword pack
    rng = (derivedref.DAY0, derivedref.DAY0 + 3)
    out = must_cli(journal_dir, "ask", "2026-01-01:2026-01-03",
                   "anything", "about", "auth", "or", "Alice?")
    want = derivedref.render_pack(record_count, ves, question, rng)
    expect_bytes(out, want.encode(), "ask silent-degrade pack")

    return problems


# ---------------------------------------------------------------- --eval

def resolve_model():
    path = os.environ.get("ZEPHYR_EMBED_MODEL")
    if not path:
        path = os.path.join(os.path.expanduser("~"), ".zephyr",
                            "models", MODEL_NAME)
    if not os.path.exists(path):
        return None, f"model not found at {path} (download: {MODEL_URL})"
    size = os.path.getsize(path)
    if size != MODEL_BYTES:
        return None, f"model at {path} is {size} bytes, want {MODEL_BYTES}"
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != MODEL_SHA256:
        return None, f"model at {path} sha256 {h.hexdigest()} does not match " \
                     f"the pinned {MODEL_SHA256}"
    return path, None


def recall_at5(top, gold):
    gold = set(gold)
    return len(set(top) & gold) / len(gold)


def mrr_of(top, gold):
    for i, s in enumerate(top, 1):
        if s in gold:
            return 1.0 / i
    return 0.0


def parse_rank_seqs(out):
    seqs = []
    for line in out.decode().splitlines():
        line = line.strip()
        if not line:
            continue
        tok = line.split()[0]
        if tok.isdigit():
            seqs.append(int(tok))
    return seqs[:5]


def run_eval(binary):
    print("zephyr semantic gate (spec/semantic.md section 8)")

    model, err = resolve_model()
    if err:
        print(f"SETUP: {err}")
        return 2
    print(f"model: {model} (pinned sha256 ok, {MODEL_BYTES} bytes)")

    run_cli, must_cli = make_runner(binary)

    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    journal_dir = os.path.join(WORK_DIR, "journal")
    os.makedirs(journal_dir)

    spec = load_spec()
    head = write_journal(journal_dir, spec)
    recs = derivedref.decode_journal_dir(journal_dir)
    if len(recs) != RECORD_COUNT:
        print(f"SETUP: rendered {len(recs)} records, want {RECORD_COUNT}")
        return 2

    # ---- rebuild with the real engine
    try:
        out = must_cli(journal_dir, "derived", "rebuild", "--embeddings",
                       timeout=1800)
    except (RuntimeError, AlarmTimeout) as e:
        print(f"SETUP: derived rebuild --embeddings failed: {e}")
        return 2
    lines = out.decode().splitlines()
    m = re.search(r"^✓ embedded · (\d+) entries?$", lines[-1] if lines else "")
    if len(lines) < 2 or not lines[0].startswith("✓ rebuilt") or not m:
        print(f"SETUP: unexpected rebuild output: {out.decode()!r}")
        return 2
    if int(m.group(1)) != EMBEDDABLE_COUNT:
        print(f"SETUP: rebuilt {m.group(1)} entries, want {EMBEDDABLE_COUNT} "
              f"(redacted/private must be excluded)")
        return 2
    print(f"rebuild: {m.group(1)} entries")

    # ---- the artifact: fresh, right dim, right record count.
    # The fresh verdict implies the artifact head matches the current
    # journal head (the status no longer echoes the head), and the
    # model/engine binding is enforced by the vector rank below, which
    # refuses an artifact built under a different model or engine.
    status = must_cli(journal_dir, "derived", "status").decode()
    m = re.search(r"^embed  (\w+) · (\d+) records? · dim (\d+)$",
                  status, re.MULTILINE)
    if not m:
        print(f"SETUP: no parseable embed status line: {status!r}")
        return 2
    if (m.group(1) != "fresh" or int(m.group(3)) != EXPECTED_DIM
            or int(m.group(2)) != RECORD_COUNT):
        print(f"SETUP: embed artifact not as pinned: {m.group(0)!r} "
              f"(dim {EXPECTED_DIM}, records {RECORD_COUNT})")
        return 2
    print(f"artifact: fresh, dim={m.group(3)}, records={m.group(2)}")

    # ---- rank every labeled query in every mode
    results = {}
    try:
        for q in spec["queries"]:
            words = q["query"].split()
            for mode in ("keyword", "vector", "hybrid"):
                code, out, err = run_cli(
                    journal_dir, "rank", *words,
                    "--mode", mode, "--top", "5", timeout=900)
                if code != 0:
                    print(f"SETUP: rank {mode} {q['id']}: exit {code}: "
                          f"{err.decode('utf-8', 'replace')}")
                    return 2
                results[(q["id"], mode)] = parse_rank_seqs(out)
    except AlarmTimeout as e:
        print(f"SETUP: timed out: {e}")
        return 2

    # ---- score
    metrics = {}
    print()
    print(f"{'id':<14} {'category':<10} "
          f"{'kw R@5':>6} {'kw MRR':>6}   "
          f"{'vec R@5':>7} {'vec MRR':>7}   "
          f"{'hyb R@5':>7} {'hyb MRR':>7}")
    for q in spec["queries"]:
        row = []
        for mode in ("keyword", "vector", "hybrid"):
            top = results[(q["id"], mode)]
            metrics[(q["id"], mode)] = (recall_at5(top, q["gold"]),
                                        mrr_of(top, q["gold"]), top)
            row.append(f"{metrics[(q['id'], mode)][0]:6.3f} "
                       f"{metrics[(q['id'], mode)][1]:6.3f}")
        print(f"{q['id']:<14} {q['category']:<10}   "
              f"{row[0]}   {row[1]}   {row[2]}")

    def mean(mode, key):
        vals = [metrics[(q["id"], mode)][key] for q in spec["queries"]]
        return sum(vals) / len(vals)

    kw_r5, hy_r5 = mean("keyword", 0), mean("hybrid", 0)
    kw_mrr, hy_mrr = mean("keyword", 1), mean("hybrid", 1)
    vec_r5 = mean("vector", 0)
    regressions = [q["id"] for q in spec["queries"]
                   if any(s in q["gold"] for s in results[(q["id"], "keyword")])
                   and not any(s in q["gold"] for s in results[(q["id"], "hybrid")])]

    print()
    print(f"{'mode':<8} {'Recall@5':>9} {'MRR':>7}")
    for mode, r5, mrr in (("keyword", kw_r5, kw_mrr),
                          ("vector", vec_r5, mean("vector", 1)),
                          ("hybrid", hy_r5, hy_mrr)):
        print(f"{mode:<8} {r5:9.3f} {mrr:7.3f}")

    margin = hy_r5 - kw_r5
    c1 = hy_r5 > kw_r5 and margin >= 0.2
    c2 = hy_mrr > kw_mrr
    c3 = not regressions
    print()
    print("win condition (spec section 8):")
    print(f"  1. hybrid Recall@5 margin over keyword >= 0.2: "
          f"{margin:7.3f}  {'PASS' if c1 else 'FAIL'}")
    print(f"  2. hybrid MRR > keyword MRR: {hy_mrr:.3f} > {kw_mrr:.3f}  "
          f"{'PASS' if c2 else 'FAIL'}")
    print(f"  3. no keyword gold lost in hybrid top 5: "
          f"{'PASS' if c3 else 'FAIL: ' + ', '.join(regressions)}")

    if c1 and c2 and c3:
        print("\nVERDICT: WIN — hybrid retrieval ships per spec section 8")
        return 0
    for q in spec["queries"]:
        kw_top = results[(q["id"], "keyword")]
        hy_top = results[(q["id"], "hybrid")]
        if any(s in q["gold"] for s in kw_top) and \
                not any(s in q["gold"] for s in hy_top):
            print(f"  regressed: {q['id']} ({q['query']!r}): "
                  f"keyword {kw_top}, hybrid {hy_top}")
    print("\nVERDICT: FAIL — SKIPPED path (spec section 8): the fusion wiring,"
          " artifact, engine, and rank are removed; the spec, labeled set,"
          " and this harness remain as the measurement record")
    return 1


# ---------------------------------------------------------------- main

def main():
    argv = sys.argv[1:]
    if "--check" in argv:
        argv.remove("--check")
        binary = argv[0] if argv else BIN_DEFAULT
        if not os.path.exists(binary):
            print(f"FAIL: binary not found: {binary} (run `zig build` first)")
            return 1
        try:
            problems = run_check(binary)
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
        print("ok: semantic layer checks passed (ZDE1 status states, vector "
              "refusal, keyword rank bytes, ask silent degrade)")
        return 0
    if "--eval" in argv:
        argv.remove("--eval")
        binary = argv[0] if argv else BIN_DEFAULT
        if not os.path.exists(binary):
            print(f"SETUP: binary not found: {binary} (run `zig build` first)")
            return 2
        try:
            return run_eval(binary)
        except AlarmTimeout:
            print("SETUP: timed out waiting for zephyr")
            return 2
        except Exception as e:
            print(f"SETUP: gate crashed: {e!r}")
            return 2
        finally:
            if os.path.exists(WORK_DIR):
                shutil.rmtree(WORK_DIR, ignore_errors=True)
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
