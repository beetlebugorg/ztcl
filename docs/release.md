# Release process

## Versions

| Tag | GitHub release | Homebrew tap |
|---|---|---|
| `vX.Y.Z` | Release | Updated |
| `vX.Y.Z-beta` | Prerelease | Updated |
| `vX.Y.Z-alpha` | Prerelease | Updated |

## Steps

1. Update `CHANGELOG.md` and the version in `build.zig.zon`.
2. Run the tests, the suite, and the wasm build.
3. Push a tag. `.github/workflows/release.yml` runs.

The workflow builds `ztcl` for Linux (x86_64, aarch64), macOS (x86_64, aarch64), and Windows (x86_64), and the WebAssembly library. It publishes the archives and `SHA256SUMS`, then writes `Formula/ztcl.rb` in `beetlebugorg/homebrew-tap`.

## Secrets

`HOMEBREW_TAP_TOKEN` is a token with write access to `beetlebugorg/homebrew-tap`. Without the secret, the workflow prints a warning, the release stays, and the tap keeps its version.

## Repository settings

The proposed description and topics are in [`.github/repo.md`](../.github/repo.md).
