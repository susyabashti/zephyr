# Zephyr MCP Server — Phase 6 (FROZEN, amended by Phase 7)

Read-only AI access to the journal over the Model Context Protocol (MCP),
stdio transport. Companion to `record-format.md`. The wire contract is
checked by `test/phase6.zig` (in-process) and `test/mcpref.py` (real
process, independent client).

**Phase 7 amendment** (`spec/derived.md` section 7): the tool list grows
from 5 to 6 read-only tools — `get_context` is added — and `get_profile`
results now carry the user's notes under a `# notes` heading (a one-line
note when `notes.md` is absent). `get_context` is read-only: the pack is
computed in memory and the server never writes or migrates derived
artifacts. The five pre-existing tools keep their byte-exact behavior.

## 1. Surface

`zephyr mcp` starts the server; the journal must already exist.
`zephyr mcp --allow-write` additionally exposes the `add_entry` tool. The
flag is CLI-only and fixed for the life of the process: no MCP request can
enable or disable writing.

## 2. Wire protocol

- JSON-RPC 2.0 over stdio, one JSON object per line, no embedded newlines
  (MCP stdio transport, 2025-06-18).
- Lines over 1 MiB are rejected with a parse error (code -32700, id null)
  and the rest of the line is discarded.
- Protocol versions: `2025-06-18` (primary). A client requesting
  `2025-03-26` is echoed; any other requested version gets `2025-06-18`.
- Lifecycle: `initialize` is the first request. `tools/list` and
  `tools/call` are rejected with -32600 until the client has sent
  `notifications/initialized`. `ping` is accepted at any time. A second
  `initialize` is -32600.
- Error codes: -32700 parse, -32600 invalid request, -32601 method not
  found, -32602 invalid params (unknown tool included, per the MCP tools
  spec), -32603 internal error.
- Advertised server capabilities: `tools` only (no `listChanged`; the tool
  list is fixed for the process). No prompts, resources, or logging.
- Server info: `{"name":"zephyr","version":<zephyr version>}`.

## 3. Provenance

Every successful tool result begins with the LLM-view provenance line:

    # zephyr: seq 0..N head=<64-hex>

where N is the last record's seq (0 for an empty journal) and the head is
the last record's `record_hash` (genesis hash for an empty journal) — the
same line the LLM view renderer emits (record-format section 9). A failed
`verify_status` carries no provenance line: the FAIL line is the report.

## 4. Verify before trust

Every tool (`get_entries`, `search`, `get_digest`, `get_profile`,
`get_context`, `add_entry`) runs the full chain verify first. A journal that fails verify
gets a tool error result (`isError: true`) naming the exact failure
(`FAIL: <file> seq <n> <field>: <detail>`) and serves no data.
`verify_status` reports the same state as data. Anchor and OTS checks are
out of scope for the server; they belong to `zephyr verify`.

## 5. Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `get_entries` | `from` date (required), `to` date (optional, inclusive) | LLM view for [from, to] |
| `search` | `query` string (required, non-empty), `limit` integer (optional, default 20, min 1) | Up to `limit` matches, in view order |
| `get_digest` | `period` = `week` \| `month` (required) | LLM view of the current week (Mon-Sun) or month, in the journal's timezone |
| `get_profile` | — | Contents of `<journal>/profile.md` (the derived profile once Phase 7 has rendered it), or a "no profile" note; the user's `notes.md` follows under a `# notes` heading (a one-line note when absent) |
| `verify_status` | — | `ok: N record(s), head <hex>[, R redacted]`, or the FAIL line |
| `get_context` | `question` string (required, non-empty), `from`/`to` dates (optional, `YYYY-MM-DD`) | The deterministic context pack (derived.md section 7), same bytes `zephyr ask` prints: provenance, question, derived profile, notes, period digest, keyword matches, answer footer. `from`/`to` bound the period (a single date covers that day); absent, a `YYYY-MM-DD` in the question, else the current week. Read-only: nothing is written. Phase 8: the matches are always the keyword list — the server never loads the embedding model, so the pack does not follow `ask`'s hybrid retrieval (semantic.md section 6). |
| `add_entry` | `text` string (required, non-empty), `tags` string[] (optional) | `logged seq N` plus the post-write provenance. Only with `--allow-write`. |

Dates are `YYYY-MM-DD` civil dates under each entry's own local timezone
(the view's grouping rule, record-format section 9). `from` > `to` and
unparseable dates are -32602.

The view rules apply to every result: private entries never appear,
tombstoned entries are omitted, redacted entries render as the
`[redacted]` marker, and amended entries show only the latest amendment
text. `search` never matches private or redacted content.

`get_profile` reads `<journal>/profile.md` (plain text, user-maintained;
the Phase 7 derived layer takes it over) and appends the user's `notes.md`
under a `# notes` heading (or a one-line note when `notes.md` is absent),
so an AI client can tell machine-fact from user-voice. The provenance line
is included even when the profile is missing.

## 6. Limits

- 1 MiB maximum line (section 2).
- `search` default limit 20; when matches are cut off, a truncation note
  is appended to the result.
- Journal reads are bounded by the on-disk journal size; the server is a
  local stdio process with no network exposure.
