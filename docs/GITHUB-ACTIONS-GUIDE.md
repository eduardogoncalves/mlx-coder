# GitHub Actions Workflow Guide

This repository ships an Apple Silicon CLI release pipeline in [.github/workflows/build-and-release.yml](../.github/workflows/build-and-release.yml).

## Triggers

- Tag push matching `v*` (for example `v0.1.0`)
- Manual `workflow_dispatch` with optional `version`

## Jobs

Tag flow:

1. Build CLI artifacts for `arm64` on macOS runner
2. Upload artifacts from the build job
3. Create a GitHub release and attach all files

Manual flow:

1. Build `arm64` artifacts
2. Upload artifacts only (no GitHub release publish)

## Build Inputs

The workflow calls [build-and-release.sh](../build-and-release.sh) and passes version through `MLX_CODER_VERSION`.

For tag pushes, version is derived from `vX.Y.Z` tags.
For manual runs, version comes from workflow input or falls back to a timestamp.

## Create a Release

```bash
git tag v0.1.0
git push origin v0.1.0
```

Then monitor the run in GitHub Actions and verify assets under the matching release.

## Manual Build (No Release Publish)

From the Actions UI:

1. Run workflow
2. Optionally set `version`
3. Download generated artifacts from the run

## Expected Release Assets

- `mlx-coder-<version>-arm64.tar.gz`
- `mlx-coder-<version>-arm64.pkg`
- `mlx-coder-<version>-arm64.sha256`
- `RELEASE_NOTES_v<version>.md`

## Required Repository Setting

Under repository Settings > Actions > General, enable workflow permissions with write access so release publishing can upload assets.

## Troubleshooting

Workflow does not trigger:

- Confirm tag starts with `v`
- Confirm workflow file exists on default branch

Missing release files:

- Check the `Upload build artifacts` step output in each build job
- Check `Publish release` step logs for file upload errors
