#!/usr/bin/env python3
"""Structural gate: layering invariants and map integrity.

Checks, without building or running anything:

  1. The module graph stays one-way (docs/map.md, "Structural invariants"):
     src/core/ imports nothing outside itself; src/mcp/ and src/embed/
     import only core (and their own directory); a command never imports
     another command.
  2. core never prints: no src/core/ file references stdout or stderr
     outside comments and string literals.
  3. The file index in docs/map.md (between the map:file-index markers)
     lists every src/**/*.zig file exactly once, and nothing else.

  python3 test/structure.py --check

Exit 0 clean, 1 violations (one FAIL line each on stderr), 2 usage.
Unlike the *ref gates this gate is structural: it reads no vectors and
spawns no binary — it keeps the architecture honest so docs/map.md can be
trusted without re-reading the imports.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "src")
MAP = os.path.join(REPO, "docs", "map.md")

IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
CHAR_LITERAL_RE = re.compile(r"'(\\u\{[^}]*\}|\\.|[^'\\])'")

# Module names that are not one of the project modules.
OPTION_MODULES = {"std_options", "embed_options", "options"}

# Which module names each zone may import (besides std, builtin, and
# option modules).
ALLOWED_MODULES = {
    "core": {"zephyr_core"},
    "mcp": {"zephyr_core"},
    "embed": {"zephyr_core", "embed_options"},
    "key": {"zephyr_core"},
    "main": set(),
    "cli": {"zephyr_core", "zephyr_mcp", "zephyr_embed", "zephyr_key"},
    "commands": {"zephyr_core", "zephyr_mcp", "zephyr_embed", "zephyr_key"},
}

# Which zones a relative import may resolve into, per zone.
REL_OK = {
    "core": {"core"},
    "mcp": {"mcp"},
    "embed": {"embed"},
    "key": {"key"},
    "main": {"main", "core", "mcp", "embed", "key", "cli", "commands"},
    "cli": {"cli", "commands"},
    "commands": {"cli"},
}


def rel(path):
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def zone_of(path):
    """The architecture zone of a src file, or None if outside src/."""
    r = rel(path)
    if r == "src/main.zig":
        return "main"
    if r == "src/core.zig" or r.startswith("src/core/"):
        return "core"
    if r == "src/mcp.zig" or r.startswith("src/mcp/"):
        return "mcp"
    if r == "src/embed.zig" or r.startswith("src/embed/"):
        return "embed"
    if r == "src/key.zig" or r.startswith("src/key/"):
        return "key"
    if r.startswith("src/cli/"):
        return "commands" if r.startswith("src/cli/commands/") else "cli"
    return None


def zig_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith(".zig"):
                out.append(os.path.join(dirpath, fn))
    return out


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def check_imports(path, text):
    problems = []
    zone = zone_of(path)
    if zone is None:
        problems.append(f"{rel(path)}: not in a known zone")
        return problems
    allowed = ALLOWED_MODULES[zone]
    for m in IMPORT_RE.finditer(text):
        name = m.group(1)
        line = line_of(text, m.start())
        if name in ("std", "builtin") or name in OPTION_MODULES:
            continue
        if name in ("zephyr_core", "zephyr_mcp", "zephyr_embed", "zephyr_key"):
            if name not in allowed:
                problems.append(
                    f"{rel(path)}:{line}: imports module {name} "
                    f"(zone {zone} may import: {sorted(allowed) or 'none'})"
                )
            continue
        if "/" in name or name.endswith(".zig"):
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), name))
            rz = zone_of(resolved) if os.path.isfile(resolved) else None
            if rz is None:
                problems.append(
                    f"{rel(path)}:{line}: import {name!r} does not resolve to a file under src/"
                )
                continue
            if zone == "commands" and rz == "commands":
                problems.append(
                    f"{rel(path)}:{line}: a command may not import another command "
                    f"({name!r}); shared helpers live in src/cli/"
                )
            elif rz not in REL_OK[zone]:
                problems.append(
                    f"{rel(path)}:{line}: imports {name!r} (a {rz} file); "
                    f"zone {zone} may import {sorted(REL_OK[zone])}"
                )
            continue
        problems.append(f"{rel(path)}:{line}: unknown import {name!r}")
    return problems


def strip_comments_and_strings(text):
    """Drop // and /* */ comments, string and char literals; keep code."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        if c == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            m = CHAR_LITERAL_RE.match(text, i)
            if m:
                i = m.end()
                continue
        out.append(c)
        i += 1
    return "".join(out)


def check_core_prints(path, text):
    problems = []
    code = strip_comments_and_strings(text)
    for m in re.finditer(r"\b(stdout|stderr)\b", code):
        problems.append(
            f"{rel(path)}:{line_of(text, m.start())}: core references "
            f"{m.group(0)} (core returns data; it does not print)"
        )
    return problems


def check_map(problems):
    """The map's file index must list exactly the set of src/**/*.zig."""
    try:
        text = open(MAP, encoding="utf-8").read()
    except OSError as e:
        problems.append(f"cannot read {rel(MAP)}: {e}")
        return 0
    m = re.search(r"<!-- map:file-index:begin -->\n(.*?)<!-- map:file-index:end -->", text, re.S)
    if not m:
        problems.append(f"{rel(MAP)}: missing the map:file-index markers")
        return 0
    listed = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        first = line.strip("|").split("|")[0].strip()
        if not (first.startswith("`") and first.endswith("`")):
            continue
        listed.append(first[1:-1])
    actual = {rel(p) for p in zig_files(SRC)}
    for p in listed:
        if listed.count(p) > 1:
            problems.append(f"{rel(MAP)}: {p} is listed twice")
    for p in sorted(actual - set(listed)):
        problems.append(f"{rel(MAP)}: {p} is missing from the file index")
    for p in sorted(set(listed) - actual):
        problems.append(f"{rel(MAP)}: {p} is listed but does not exist")
    return len(listed)


def main():
    args = [a for a in sys.argv[1:] if a.startswith("--")]
    if not args:
        print(__doc__)
        sys.exit(2)
    if "--check" not in args:
        print("unknown option (use --check)", file=sys.stderr)
        sys.exit(2)
    problems = []
    files = zig_files(SRC)
    for path in files:
        text = open(path, encoding="utf-8").read()
        problems += check_imports(path, text)
        if zone_of(path) == "core":
            problems += check_core_prints(path, text)
    n_listed = check_map(problems)
    if problems:
        for p in problems:
            print("FAIL:", p, file=sys.stderr)
        sys.exit(1)
    print(f"ok: {len(files)} src file(s) layered, core clean, map in sync ({n_listed} listed)")


if __name__ == "__main__":
    main()
