#!/bin/bash
# Report the installed Zig version and whether it falls within the documented range.
# Set ZIG_CMD to point at a specific/vendored toolchain.
set -e

ZIG_CMD="${ZIG_CMD:-zig}"

if ! command -v "$ZIG_CMD" &> /dev/null; then
    echo "ERROR: zig not found. Set ZIG_CMD or add zig to PATH."
    exit 1
fi

VERSION=$("$ZIG_CMD" version)
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)

echo "Detected Zig version: $VERSION"

if [[ "$MAJOR" -eq 0 && "$MINOR" -ge 15 && "$MINOR" -le 17 ]]; then
    echo "OK: within the documented range (0.15.x, 0.16.0, 0.17.0)."
    echo "    Reference: references/zig-0.${MINOR}.md"
    exit 0
elif [[ "$MAJOR" -eq 0 && "$MINOR" -lt 15 ]]; then
    echo "WARNING: older than the documented range (0.15-0.17). APIs here may not apply."
    exit 1
else
    echo "WARNING: newer than the documented range (0.15-0.17). Verify APIs against local docs."
    exit 1
fi
