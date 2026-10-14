# zephyr development tasks. Requires: just, Zig 0.17, Python 3.
# Run `just` to list the recipes.

default:
    just --list

build:
    zig build

build-release:
    zig build -Doptimize=ReleaseFast

test:
    zig build test

fmt:
    zig build fmt

# The byte-exact gates (run a fresh `zig build` first).
gates: build
    python3 test/reference.py --check
    python3 test/otsref.py --check
    python3 test/mcpref.py --check
    python3 test/derivedref.py --check
    python3 test/semref.py --check

# Retrieval eval with the real model (slow).
eval: build
    python3 test/semref.py --eval

# 100k-entry round trip (slow).
roundtrip:
    zig build roundtrip -Doptimize=ReleaseFast

# Build ReleaseFast and drop the binary in ~/.local/bin.
install-local: build-release
    mkdir -p ~/.local/bin
    install -m 755 zig-out/bin/zephyr ~/.local/bin/zephyr

release:
    @echo "1. on a clean tree:            just test && just gates"
    @echo "2. bump cli.Version:            src/cli/cli.zig"
    @echo "3. commit and tag:              git commit -am 'release: vX.Y.Z' && git tag vX.Y.Z"
    @echo "4. push (workflow does the rest): git push origin main vX.Y.Z"
