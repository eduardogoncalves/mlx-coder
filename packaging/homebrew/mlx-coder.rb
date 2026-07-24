# typed: true
# frozen_string_literal: true

# Homebrew formula for mlx-coder (Apple Silicon CLI).
#
# This is the *canonical* copy that lives in the mlx-coder repo. The copy that
# users actually `brew install` lives in the tap repo:
#
#     github.com/eduardogoncalves/homebrew-tap  ->  Formula/mlx-coder.rb
#
# Keep them in sync with: ./scripts/update-formula.sh --version X.Y.Z --push
#
# Why a "binary" formula (download prebuilt tarball) instead of build-from-source:
#   Building MLX from source pulls the full mlx-swift / mlx-swift-lm graph and
#   compiles Metal shaders — minutes of work and a large toolchain on the user's
#   machine. Shipping the already-built arm64 tarball is the reliable path.
#
# Why libexec + an exec wrapper instead of a plain bin symlink:
#   The MLX runtime resolves default.metallib relative to the *real* binary
#   location (via dladdr) and via NS::Bundle::mainBundle(). Homebrew exposes
#   binaries through symlinks in the shared bin dir, so we cannot drop the
#   mlx-swift_Cmlx.bundle next to the invoked path. Installing both the binary
#   and the bundle into libexec (a real, private dir) and exec'ing the real
#   binary from a wrapper reproduces exactly the adjacent-bundle layout that the
#   released .tar.gz already proves works.
class MlxCoder < Formula
  desc "Local, MLX-powered coding agent CLI for Apple Silicon"
  homepage "https://github.com/eduardogoncalves/mlx-coder"
  # Homebrew requires `url` before `version`, so the version is written literally
  # here (not interpolated). scripts/update-formula.sh rewrites the url, version,
  # and sha256 lines together on each release.
  url "https://github.com/eduardogoncalves/mlx-coder/releases/download/v2.4.0/mlx-coder-2.4.0-arm64.tar.gz"
  version "2.4.0"
  sha256 "0e8b2409cd981e6ab64005420a49c260867075f02d7c93e8ac5d5dcb61938c4b"
  license "MIT"

  # Apple Silicon only, and the binary targets macOS 15 (Sequoia) or newer.
  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    # Keep the binary and its Metal shader bundle side by side in a real dir.
    libexec.install "mlx-coder"
    libexec.install "mlx-swift_Cmlx.bundle"

    # Expose a thin wrapper on PATH. `exec` replaces the shell with the real
    # binary launched by its absolute libexec path, so dladdr/mainBundle resolve
    # the colocated mlx-swift_Cmlx.bundle correctly.
    (bin/"mlx-coder").write <<~SH
      #!/bin/bash
      exec "#{libexec}/mlx-coder" "$@"
    SH
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/mlx-coder --version")
  end
end
