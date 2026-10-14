# Releasing zephyr

Releasing is a **tag push**. The [release
workflow](../.github/workflows/release.yml) does everything else: it builds
`ReleaseFast` binaries for all four supported targets, packages them,
publishes checksums, and uploads the release.

## Procedure

```sh
# 0. on a clean tree, everything green:
just test && just gates        # or: zig build test && python3 test/*.py --check

# 1. bump the version — it is the single source of truth for the tag:
#    src/cli/cli.zig  →  pub const Version: []const u8 = "0.2.1";
git commit -am "release: v0.2.1"

# 2. tag and push (main and the tag; the tag push fires the workflow):
git tag v0.2.1
git push origin main v0.2.1
```

Watch the run at `github.com/susyabashti/zephyr/actions`. When it is green,
the release exists with its artifacts, and `install.sh` picks it up
automatically (it resolves the latest release by default).

Write the release notes in the GitHub UI (or amend the tag's associated
release) before telling anyone — the notes are the user-facing changelog.

## What the workflow produces

| Artifact | Contents |
| --- | --- |
| `zephyr-<version>-<target>.tar.gz` | the `zephyr` binary (ReleaseFast) |
| `sha256sums.txt` | one `sha256  filename` line per tarball |

Targets and runners: `darwin-arm64` (macos-14), `darwin-x64` (macos-13),
`linux-x64` (ubuntu-22.04), `linux-arm64` (ubuntu-24.04-arm). The first tag
of a while doubles as the smoke test for the release path itself — if a
runner or toolchain changed, expect to iterate on the workflow, not the
code.

Users verify an install by checking the tarball against the published sums:

```sh
shasum -a 256 -c sha256sums.txt    # macOS (or: sha256sum -c …)
```

`install.sh` does exactly this before installing.

## Republishing and repairs

- **Re-run a failed build for the same tag:** Actions → release →
  Re-run jobs. The upload step overwrites the release's assets.
- **Re-publish a different build for an existing tag** (e.g. after a
  workflow fix): the manual dispatch form — Actions → release →
  Run workflow — takes the existing tag name and rebuilds everything.
- **The tag is wrong:** delete the tag and the release, fix, and re-tag.
  Users who installed the bad version re-run `install.sh` with
  `ZEPHYR_VERSION=vX.Y.Z` to pick up the replacement (checksums change
  with the build, so a tampered or stale cache cannot hide it).

## Versioning

`cli.Version` in `src/cli/cli.zig` is printed by `zephyr --version` and
must match the tag (`v0.2.1` ↔ `0.2.1`). Bump it in the release commit,
never after the tag exists.

Semver in practice: the journal format is v1 and the derived/semantic
artifact formats are frozen by `spec/`; changes that invalidate stored
artifacts (engine pin, model pin, prompt or pooling) are minor bumps,
format changes are major bumps.
