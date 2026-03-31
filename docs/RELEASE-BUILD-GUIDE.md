# macOS CLI Build and Release Guide

This guide covers the local CLI build flow implemented by [build-and-release.sh](../build-and-release.sh) and the CI release automation in [.github/workflows/build-and-release.yml](../.github/workflows/build-and-release.yml).

## What the Script Produces

- A CLI archive named `mlx-coder-<version>-arm64.tar.gz`
- A macOS installer named `mlx-coder-<version>-arm64.pkg`
- A checksum file named `mlx-coder-<version>-arm64.sha256`
- Release notes `RELEASE_NOTES_v<version>.md`

All artifacts are written to the `releases/` directory.

## Prerequisites

- macOS 14+
- Xcode 16+ command line tooling (`xcodebuild`, `pkgbuild`, `pkgutil`)

## Local Build

Build release artifacts for Apple Silicon:

```bash
chmod +x ./build-and-release.sh
MLX_CODER_VERSION=0.1.0 ./build-and-release.sh arm64
```

Only `arm64` is supported.

## Verify Artifacts

```bash
shasum -a 256 -c releases/mlx-coder-0.1.0-arm64.sha256
sudo installer -pkg releases/mlx-coder-0.1.0-arm64.pkg -target /
/usr/local/bin/mlx-coder --version
```

## Automated GitHub Release

Tag push flow:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow then:

1. Builds Apple Silicon CLI artifacts (`.tar.gz`, `.pkg`, `.sha256`)
2. Publishes checksums and notes as artifacts
3. Creates a GitHub release for the tag
4. Uploads all release files

Manual workflow dispatch is also supported.

## Troubleshooting

`xcodebuild not found`:

```bash
xcode-select --install
```

Checksum verification fails:

Make sure the `.tar.gz`, `.pkg`, and `.sha256` come from the same build.

## Notes on Signing

Current automation builds unsigned artifacts. For public distribution, add code signing and notarization in CI before publishing.
