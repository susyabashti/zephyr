# Zephyr MCP Server — Phase 6 (FROZEN, amended by Phase 7)

Read-only AI access to the journal over the Model Context Protocol (MCP),
stdio transport. Companion to `record-format.md`. The wire contract is
checked by `test/phase6.zig` (in-process) and `test/mcpref.py` (real
process, independent client).

**Phase 7 amendment** (`spec/derived.md` section 7): the tool list grows
from 5 to 6 read-only tools — `get_context` is added — and `get_profile`
results now carry the user's notes. `get_context` is read-only: the pack is
computed in memory and the server never writes or migrates derived
artifacts.

**Display amendment (Phase B)**: results carry no provenance line (section
3) — `get_entries`/`search`/`get_digest` serve the clean LLM view,
`get_profile` renders the *computed* derived profile (never the bytes of
`profile.md`), and `get_context` serves the new pack layout
(`spec/derived.md` section 7). `verify_status` reports `ok · N records`
or `✗ <file> seq <n> <field>: <detail>`; `add_entry` reports `logged seq N`.

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

Tool results carry **no** provenance line: the fingerprint of the log state
(the head) is an integrity primitive, not reading material. It lives in the
on-disk derived artifacts (their machine headers) and behind
`zephyr verify --head`. Every result is still produced only from a journal
that passed verify (section 4), so removing the printed hex changes nothing
about what is verified.

## 4. Verify before trust

Every tool (`get_entries`, `search`, `get_digest`, `get_profile`,
`get_context`, `add_entry`) runs the full chain verify first. A journal that fails verify
gets a tool error result (`isError: true`) naming the exact failure
(`✗ <file> seq <n> <field>: <detail>`) and serves no data. A refused data
tool's text keeps the `journal failed verify:` prefix before the failure
line. `verify_status` reports the same state as data. Anchor and OTS checks
are out of scope for the server; they belong to `zephyr verify`.

## 5. Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `get_entries` | `from` date (required), `to` date (optional, inclusive) | The LLM view for [from, to] (record-format section 9); empty text when no entries fall in the range |
| `search` | `query` string (required, non-empty), `limit` integer (optional, default 20, min 1) | A match count label, a blank line, up to `limit` match lines in view order; a truncation note when cut |
| `get_digest` | `period` = `week` \| `month` (required) | The digest display body (derived.md section 5) for the current week (Mon-Sun) or month, in the journal's timezone |
| `get_profile` | — | The *computed* derived profile display body (derived.md section 6), with the user's `notes.md` first under `notes` / `about you` when present (absent → the body at column 0). The server renders from the log; `profile.md` on disk is never read or written by it |
| `verify_status` | — | `ok · N record(s)[ · R redacted]`, or `✗ <file> seq <n> <field>: <detail>` (tool error) |
| `get_context` | `question` string (required, non-empty), `from`/`to` dates (optional, `YYYY-MM-DD`) | The deterministic context pack (derived.md section 7), same bytes `zephyr ask` prints: question, profile, notes, period digest, matching entries, answer footer. `from`/`to` bound the period (a single date covers that day); absent, a `YYYY-MM-DD` in the question, else the current week. Read-only: nothing is written. The matches are always the keyword list — the server never loads the embedding model, so the pack does not follow `ask`'s hybrid retrieval (semantic.md section 6). |
| `add_entry` | `text` string (required, non-empty), `tags` string[] (optional) | `logged seq N`. Only with `--allow-write`. |

Dates are `YYYY-MM-DD` civil dates under each entry's own local timezone
(the view's grouping rule, record-format section 9). `from` > `to` and
unparseable dates are -32602.

The view rules apply to every result: private entries never appear,
tombstoned entries are omitted, redacted entries render as the
`[redacted]` marker, and amended entries show only the latest amendment
text. `search` never matches private or redacted content.

`get_profile` renders the derived profile **from the verified log**
(computed in memory — the index is rebuilt for the call, nothing is
written), presented per derived.md section 6: the user's `notes.md` first
under `notes`, then the profile body under `about you` (both indented two
spaces); without `notes.md` the body stands at column 0. An empty journal
renders `0 entries`. A `profile.md` left on disk by a pre-Phase-7 install is
ignored until a CLI read migrates it.

## 6. Limits

- 1 MiB maximum line (section 2).
- `search` default limit 20; when matches are cut off, a truncation note
  is appended to the result.
- Journal reads are bounded by the on-disk journal size; the server is a
  local stdio process with no network exposure.
