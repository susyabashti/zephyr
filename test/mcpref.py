#!/usr/bin/env python3
"""Independent end-to-end gate for the MCP server (spec/mcp.md).

Spawns the real zephyr binary as `zephyr --journal <dir> mcp` and speaks
newline-delimited JSON-RPC to it over stdio — the same channel a real MCP
client uses. The fixture journal is rendered by test/reference.py, so the
bytes the server serves were produced by the independent reference
implementation, not by the Zig code under test.

Checks (spec/mcp.md sections 2, 4, 5, 6, plus the Phase 7 amendment):
  - the initialize handshake (version echo, capabilities) and lifecycle;
  - tools/list advertises the six read-only tools (incl. get_context),
    never add_entry;
  - get_entries and search respect the view rules (private excluded,
    redacted marker, provenance line first);
  - verify-before-trust: a corrupted chain is flagged by verify_status
    and every data tool refuses; restoring the bytes restores service;
  - add_entry is a protocol error by default, and appends a real entry
    when the server was started with --allow-write (a separate process);
  - a line over 1 MiB is one parse error and the server keeps going;
  - get_profile serves the document or its absence, plus the user's
    notes under a # notes heading (Phase 7);
  - get_context serves the deterministic context pack: provenance,
    question, profile, notes, the period digest, matches, footer —
    byte-identical to a second call, and period-bounded by from/to.

Usage:
  python3 test/mcpref.py --check [path-to-zephyr]

The binary defaults to zig-out/bin/zephyr; run `zig build` first.
"""

import json
import os
import shutil
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import reference

BIN_DEFAULT = os.path.join(HERE, "..", "zig-out", "bin", "zephyr")
WORK_DIR = os.path.join(HERE, "..", ".tmp-mcpref")

# 2026-01-01T00:00:00Z — a Thursday (spec view lines say "Thu").
BASE = 1_767_225_600_000


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
            "salt_hex": format(seq, "064x"),  # 32-byte salt, 64 hex chars
        }

    return {
        "segments": [
            {
                "name": "2026-01.zph",
                "sealed": False,
                "records": [
                    rec(0, "entry", "shipped the auth fix", ["work"], 3_600_000),
                    rec(1, "entry", "PRIVATE-MCP-MARKER-4d7e", ["priv"], 7_200_000, private=True),
                    rec(2, "entry", "sensitive meeting notes", [], 10_800_000),
                    rec(3, "entry", "walked the dog", [], 14_400_000),
                    rec(4, "redaction", "", [], 18_000_000, target_seq=2),
                ],
            },
        ],
    }


def write_journal(journal_dir):
    """Renders the fixture with the reference implementation into the dir."""
    files, head = reference.render_journal(fixture_journal())
    for name, data in files.items():
        with open(os.path.join(journal_dir, name), "wb") as f:
            f.write(data)
    return head


# ---------------------------------------------------------------- client

class McpClient:
    """Speaks newline-delimited JSON-RPC over the child's stdio."""

    def __init__(self, binary, journal_dir, allow_write=False):
        cmd = [binary, "--journal", journal_dir, "mcp"]
        if allow_write:
            cmd.append("--allow-write")
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.next_id = 0

    def _write(self, obj):
        self.proc.stdin.write(json.dumps(obj).encode("utf-8") + b"\n")
        self.proc.stdin.flush()

    def _read(self):
        line = self.proc.stdout.readline()
        if not line:
            err = self.proc.stderr.read().decode("utf-8", "replace")
            raise RuntimeError(
                f"server closed stdout (exit {self.proc.poll()}); stderr: {err}"
            )
        return json.loads(line.decode("utf-8"))

    def request(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self._write(msg)
        return self._read()

    def notify(self, method):
        self._write({"jsonrpc": "2.0", "method": method})

    def close(self):
        self.proc.stdin.close()
        return self.proc.wait()


# ---------------------------------------------------------------- gate

def run_gate(binary):
    problems = []

    def expect(cond, msg):
        if not cond:
            problems.append(msg)

    def call(c, name, args=None):
        params = {"name": name}
        if args is not None:
            params["arguments"] = args
        resp = c.request("tools/call", params)
        text = ""
        if "result" in resp:
            for part in resp["result"].get("content", []):
                text += part.get("text", "")
        return resp, text

    def handshake(c):
        resp = c.request("initialize", {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "mcpref", "version": "0"},
            "capabilities": {},
        })
        result = resp.get("result", {})
        expect(result.get("protocolVersion") == "2025-06-18",
               f"initialize: protocolVersion not echoed: {resp}")
        expect("tools" in result.get("capabilities", {}),
               f"initialize: no tools capability: {resp}")
        expect(result.get("serverInfo", {}).get("name") == "zephyr",
               f"initialize: serverInfo: {resp}")
        c.notify("notifications/initialized")

    # ---- read-only server ------------------------------------------
    ro_dir = os.path.join(WORK_DIR, "read")
    os.makedirs(ro_dir)
    head = write_journal(ro_dir)
    prov = f"# zephyr: seq 0..4 head={head.hex()}\n"

    c = McpClient(binary, ro_dir)
    try:
        handshake(c)

        resp = c.request("tools/list")
        tools = resp.get("result", {}).get("tools", [])
        names = [t.get("name") for t in tools]
        expect(names == ["get_entries", "search", "get_digest", "get_profile",
                         "verify_status", "get_context"],
               f"tools/list: {names}")
        for t in tools:
            expect("inputSchema" in t, f"tools/list: {t.get('name')} has no inputSchema")

        # add_entry is a protocol error, not a tool error, by default.
        resp, _ = call(c, "add_entry", {"text": "hello"})
        err = resp.get("error") or {}
        expect(err.get("code") == -32602 and "unknown tool" in err.get("message", ""),
               f"add_entry gated: {resp}")

        resp, text = call(c, "get_entries", {"from": "2026-01-01", "to": "2026-01-01"})
        expect(text.startswith(prov), f"get_entries: provenance line: {text!r}")
        for needle in ("# 2026-01-01 Thu", "01:00 [work] shipped the auth fix",
                       "03:00 [redacted]", "04:00 walked the dog"):
            expect(needle in text, f"get_entries: missing {needle!r}: {text!r}")
        for leaked in ("PRIVATE-MCP-MARKER-4d7e", "sensitive meeting notes", "[priv]"):
            expect(leaked not in text, f"get_entries: leaked {leaked!r}")

        resp, text = call(c, "search", {"query": "THE", "limit": 1})
        expect("# 1 match for \"THE\"" in text, f"search: {text!r}")
        expect("0000  2026-01-01 01:00  [work] shipped the auth fix" in text, f"search: {text!r}")
        expect("walked the dog" not in text, f"search: limit ignored: {text!r}")
        expect("1 more match(es) not shown" in text, f"search: {text!r}")
        resp, text = call(c, "search", {"query": "PRIVATE-MCP-MARKER"})
        expect("# 0 matches for \"PRIVATE-MCP-MARKER\"" in text, f"search private: {text!r}")

        resp, text = call(c, "verify_status")
        expect(text.startswith(prov), f"verify_status: provenance: {text!r}")
        expect("ok: 5 record(s)" in text, f"verify_status: {text!r}")
        expect(", 1 redacted" in text, f"verify_status: {text!r}")

        # Corrupt record 0's stored record_hash (byte 30+3 of the file) —
        # the same corruption as the phase 6 in-process test.
        seg_path = os.path.join(ro_dir, "2026-01.zph")
        with open(seg_path, "rb") as f:
            data = f.read()
        corrupted = bytearray(data)
        corrupted[33] ^= 0x01
        with open(seg_path, "wb") as f:
            f.write(corrupted)

        resp, text = call(c, "verify_status")
        expect(resp.get("result", {}).get("isError") is True, f"corrupt verify_status: {resp}")
        expect("FAIL: 2026-01.zph seq 0" in text, f"corrupt verify_status: {text!r}")
        expect("# zephyr:" not in text, f"corrupt verify_status: provenance leaked: {text!r}")
        resp, text = call(c, "get_entries", {"from": "2026-01-01"})
        expect("journal failed verify" in text, f"corrupt get_entries: {text!r}")
        expect("shipped the auth fix" not in text, f"corrupt get_entries: served data: {text!r}")

        with open(seg_path, "wb") as f:
            f.write(data)
        resp, text = call(c, "verify_status")
        expect("ok: 5 record(s)" in text, f"restored verify_status: {text!r}")

        # A line over 1 MiB is one parse error; the server keeps going.
        raw = (b'{"jsonrpc":"2.0","id":901,"method":"ping","params":{"pad":"'
               + b"x" * ((1 << 20) + 100) + b'"}}\n')
        c.proc.stdin.write(raw)
        c.proc.stdin.flush()
        resp = c._read()
        expect(resp.get("error", {}).get("code") == -32700, f"oversized line: {resp}")
        expect(resp.get("id") is None, f"oversized line id: {resp}")
        resp = c.request("ping")
        expect(resp.get("result") == {}, f"ping after oversized line: {resp}")

        resp, text = call(c, "get_profile")
        expect(text.startswith(prov), f"get_profile: provenance: {text!r}")
        expect("no profile document at profile.md" in text, f"get_profile: {text!r}")
        expect("# notes\n(no notes)\n" in text, f"get_profile: no-notes note: {text!r}")
        with open(os.path.join(ro_dir, "profile.md"), "w", encoding="utf-8") as f:
            f.write("# Profile\n- building Zephyr in Zig\n")
        with open(os.path.join(ro_dir, "notes.md"), "w", encoding="utf-8") as f:
            f.write("I live in Berlin.\n")
        resp, text = call(c, "get_profile")
        expect("# Profile" in text, f"get_profile present: {text!r}")
        expect("- building Zephyr in Zig" in text, f"get_profile present: {text!r}")
        expect("# notes\nI live in Berlin.\n" in text, f"get_profile notes: {text!r}")

        # get_context: the pack is deterministic (same bytes twice), carries
        # the fixed sections in order, and from/to bound the digest period.
        # "auth" is a token of fixture entry 0; the rest are stopwords.
        resp, text1 = call(c, "get_context", {"question": "anything about auth?", "from": "2026-01-01", "to": "2026-01-01"})
        resp2, text2 = call(c, "get_context", {"question": "anything about auth?", "from": "2026-01-01", "to": "2026-01-01"})
        expect(text1 == text2, f"get_context not deterministic: {text1!r} vs {text2!r}")
        expect(text1.startswith(prov), f"get_context: provenance: {text1!r}")
        expect("# question: anything about auth?\n" in text1, f"get_context: question: {text1!r}")
        expect("# notes\nI live in Berlin.\n" in text1, f"get_context: notes: {text1!r}")
        expect("# zephyr-digest: period=2026-01-01..2026-01-01" in text1,
               f"get_context: period: {text1!r}")
        expect(text1.rstrip().endswith(
            "Answer using only the entries above; cite seqs; "
            "say so if the answer is not present."),
            f"get_context: footer: {text1!r}")
        # Retrieval is exact-token (not substring): entry 0 carries "auth".
        expect("0000  " in text1, f"get_context: matches: {text1!r}")
        expect("PRIVATE-MCP-MARKER-4d7e" not in text1, f"get_context: private leaked: {text1!r}")
        expect("sensitive meeting notes" not in text1, f"get_context: redacted leaked: {text1!r}")
        # A stopword-only question still gets the pack, without matches.
        resp, text3 = call(c, "get_context", {"question": "what"})
        expect("# 0 matches for \"what\"\n" not in text3, f"get_context: no match section expected: {text3!r}")
        expect("# notes" in text3, f"get_context: notes: {text3!r}")

        resp, _ = call(c, "get_digest", {"period": "year"})
        expect(resp.get("error", {}).get("code") == -32602, f"get_digest year: {resp}")
        # "week" is accepted; do not assert on entry content — the fixture
        # date (2026-01-01) may or may not fall in the current week.
        resp, text = call(c, "get_digest", {"period": "week"})
        expect(text.startswith(prov), f"get_digest week: {text!r}")
    finally:
        code = c.close()
        expect(code == 0, f"read-only server exited {code}")

    # ---- write-enabled server (separate process) -------------------
    wr_dir = os.path.join(WORK_DIR, "write")
    os.makedirs(wr_dir)
    write_journal(wr_dir)

    w = McpClient(binary, wr_dir, allow_write=True)
    try:
        handshake(w)
        resp = w.request("tools/list")
        names = [t.get("name") for t in resp.get("result", {}).get("tools", [])]
        expect("add_entry" in names and len(names) == 7, f"write tools/list: {names}")
        expect(names[-1] == "add_entry", f"write tools/list: add_entry last: {names}")

        resp, text = call(w, "add_entry", {"text": "MCP-REF-WRITE-9c31", "tags": ["mcp"]})
        expect("logged seq 5" in text, f"add_entry: {text!r}")
        expect("# zephyr: seq 0..5 head=" in text, f"add_entry: {text!r}")
        resp, text = call(w, "search", {"query": "MCP-REF-WRITE"})
        expect("0005  " in text, f"search new entry: {text!r}")
        expect("[mcp] MCP-REF-WRITE-9c31" in text, f"search new entry: {text!r}")
    finally:
        code = w.close()
        expect(code == 0, f"write server exited {code}")

    return problems


# ---------------------------------------------------------------- driver

def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        sys.exit(2)

    if "--check" not in argv:
        print(__doc__)
        sys.exit(2)

    i = argv.index("--check")
    binary = argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith("--") else BIN_DEFAULT
    if not os.path.exists(binary):
        print(f"FAIL: zephyr binary not found at {binary} (run zig build first)", file=sys.stderr)
        sys.exit(1)

    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(90)
    shutil.rmtree(WORK_DIR, ignore_errors=True)
    try:
        problems = run_gate(binary)
    except AlarmTimeout:
        problems = ["gate timed out after 90s (server hung?)"]
    except Exception as e:
        problems = [f"gate crashed: {type(e).__name__}: {e}"]
    finally:
        signal.alarm(0)
        shutil.rmtree(WORK_DIR, ignore_errors=True)

    if problems:
        for p in problems:
            print("FAIL:", p, file=sys.stderr)
        sys.exit(1)
    print("ok: mcp server checks passed (handshake, tools, views, verify-before-trust, "
          "oversized line, profile, digest, gated write)")


if __name__ == "__main__":
    main()
