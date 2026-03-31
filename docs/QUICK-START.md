# mlx-coder Quick Start

This quick start is for local macOS development and usage.

## Build

Use Xcode build tooling (required for MLX Metal shader artifacts):

```bash
xcodebuild -scheme MLXCoder -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode
```

Install the executable and shader bundle:

```bash
sudo cp .build/xcode/Build/Products/Release/MLXCoder /usr/local/bin/mlx-coder
sudo cp -R .build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle /usr/local/bin/
mlx-coder --version
```

## Run

Interactive chat:

```bash
mlx-coder chat
```

Single prompt:

```bash
mlx-coder run --prompt "Summarize this repository"
```

Diagnostics:

```bash
mlx-coder doctor --strict --json
```

## Build Release Artifacts

Create Apple Silicon CLI artifacts:

```bash
chmod +x ./build-and-release.sh
MLX_CODER_VERSION=0.1.0 ./build-and-release.sh arm64
```

Outputs are in `releases/`.

## Install from pkg

```bash
shasum -a 256 -c releases/mlx-coder-0.1.0-arm64.sha256
sudo installer -pkg releases/mlx-coder-0.1.0-arm64.pkg -target /
/usr/local/bin/mlx-coder --version
```

## More Docs

- [README](../README.md)
- [INSTALL](../INSTALL.md)
- [Release Build Guide](./RELEASE-BUILD-GUIDE.md)
- [GitHub Actions Guide](./GITHUB-ACTIONS-GUIDE.md)
