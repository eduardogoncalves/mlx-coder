# Homebrew distribution

mlx-coder ships to macOS users through a Homebrew **tap** (a second GitHub repo
that hosts the formula). This is the free, trust-warning-free path: a
`brew`-installed CLI is not quarantined, so Gatekeeper never blocks it — no Apple
Developer account, code signing, or notarization required.

- `mlx-coder.rb` — the **canonical** formula. Edit it here.
- `../../scripts/update-formula.sh` — refreshes the version + sha256 for a
  published release and (with `--push`) copies it into the tap repo.

## One-time setup

1. **Create the tap repo.** It MUST be named `homebrew-tap` so that
   `brew tap eduardogoncalves/tap` resolves to it:

   ```bash
   gh repo create eduardogoncalves/homebrew-tap --public \
     --description "Homebrew tap for mlx-coder"
   ```

2. **Publish the current formula** into it:

   ```bash
   scripts/update-formula.sh --version 2.4.0 --push
   ```

   That creates `Formula/mlx-coder.rb` in the tap and pushes it.

3. **Verify install** on any Apple Silicon Mac:

   ```bash
   brew install eduardogoncalves/tap/mlx-coder
   mlx-coder --version
   ```

## On every release

After `scripts/release.sh --version X.Y.Z` has built and the tag `vX.Y.Z` is
published on GitHub (with the `-arm64.tar.gz` + `.sha256` assets), sync the tap:

```bash
scripts/update-formula.sh --version X.Y.Z --push
```

Users then get it with `brew upgrade mlx-coder`.

## Why this layout (libexec + exec wrapper)

The MLX runtime resolves `default.metallib` relative to the *real* binary
location (via `dladdr`) and via `NS::Bundle::mainBundle()`. Homebrew exposes
binaries as symlinks in a shared `bin`, so we cannot place the
`mlx-swift_Cmlx.bundle` next to the invoked symlink. The formula therefore
installs the binary **and** the bundle into `libexec` (a real, private dir) and
puts a thin `exec` wrapper on `PATH`. `exec` launches the real binary by its
absolute `libexec` path, reproducing the adjacent-bundle layout that the
released `.tar.gz` already relies on.

## Future: signed + notarized direct downloads

Homebrew covers the common case for free. If you later want the `.pkg`/`.tar.gz`
downloaded straight from the Releases page to open without a Gatekeeper prompt,
that requires an Apple Developer Program membership (US$99/yr) plus
`codesign` + `productsign` + `notarytool` + `stapler` steps in
`build-and-release.sh`. Not needed for the Homebrew path.
