#!/bin/sh
# Install zephyr from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/susyabashti/zephyr/main/install.sh | sh
#
# Install a specific version:
#
#   ZEPHYR_VERSION=v0.2.1 sh install.sh
#   sh install.sh v0.2.1
#
# The release artifacts are verified against the published sha256sums.txt
# before anything is installed. The binary is placed in
# $ZEPHYR_INSTALL_DIR (default: ~/.local/bin); the journal, the model, and
# everything else the CLI creates live in your home directory, so
# upgrading is a single-file replacement.

set -eu

REPO="susyabashti/zephyr"
OS=$(uname -s)
ARCH=$(uname -m)

case "$OS/$ARCH" in
    Darwin/arm64) TARGET="darwin-arm64" ;;
    Darwin/x86_64) TARGET="darwin-x64" ;;
    Linux/x86_64) TARGET="linux-x64" ;;
    Linux/aarch64) TARGET="linux-arm64" ;;
    *)
        echo "zephyr: unsupported platform: $OS/$ARCH" >&2
        exit 1
        ;;
esac

VERSION="${ZEPHYR_VERSION:-${1:-}}"
if [ -z "$VERSION" ]; then
    LATEST=$(
        curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
            grep -o '"tag_name"[^,]*' | cut -d'"' -f4
    )
    if [ -z "$LATEST" ]; then
        echo "zephyr: could not determine the latest release (is the network reachable?)" >&2
        exit 1
    fi
    VERSION="$LATEST"
fi
case "$VERSION" in
    v*) ;;
    *) VERSION="v$VERSION" ;;
esac

# shasum (macOS) or sha256sum (Linux).
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

if ! command -v curl >/dev/null 2>&1; then
    echo "zephyr: curl is required" >&2
    exit 1
fi

INSTALL_DIR="${ZEPHYR_INSTALL_DIR:-$HOME/.local/bin}"
ARTIFACT="zephyr-$VERSION-$TARGET.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/$VERSION"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "zephyr: installing $VERSION ($TARGET)"
curl -fSL --retry 3 --progress-bar -o "$TMP/$ARTIFACT" "$BASE_URL/$ARTIFACT"
curl -fSL --retry 3 -o "$TMP/sha256sums.txt" "$BASE_URL/sha256sums.txt" 2>/dev/null

EXPECTED=$(grep -F " $ARTIFACT" "$TMP/sha256sums.txt" | head -n 1 | awk '{print $1}')
if [ -z "$EXPECTED" ]; then
    echo "zephyr: $ARTIFACT not listed in sha256sums.txt" >&2
    exit 1
fi
ACTUAL=$(sha256_of "$TMP/$ARTIFACT")
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "zephyr: sha256 mismatch for $ARTIFACT" >&2
    echo "zephyr:   expected $EXPECTED" >&2
    echo "zephyr:   actual   $ACTUAL" >&2
    exit 1
fi
echo "zephyr: checksum ok"

mkdir -p "$TMP/extract"
tar -xzf "$TMP/$ARTIFACT" -C "$TMP/extract"
if [ ! -f "$TMP/extract/zephyr" ]; then
    echo "zephyr: the archive does not contain the zephyr binary" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$TMP/extract/zephyr" "$INSTALL_DIR/zephyr"
chmod 755 "$INSTALL_DIR/zephyr"

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        echo "zephyr: note: $INSTALL_DIR is not in your PATH; add it to run zephyr directly" >&2
        ;;
esac

echo "zephyr: installed to $INSTALL_DIR/zephyr"
"$INSTALL_DIR/zephyr" --version
