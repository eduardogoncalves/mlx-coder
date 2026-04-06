# VendoredVLM

Vendored sources from adrgrondin/mlx-swift-lm@67b5729e3d47d8709e03417129a1ea9ed4f19ada,
tracking upstream PR #180 (Gemma4 VLM support), which is not yet merged into
ml-explore/mlx-swift-lm.

## Cleanup

Once PR #180 is released in an official ml-explore/mlx-swift-lm version:

1. Delete this directory (`Sources/VendoredVLM/`)
2. Remove the `VendoredVLM` target from `Package.swift`
3. Remove `VendoredVLM` from `AgentCore`'s dependency list
4. Replace `import VendoredVLM` with `import MLXVLM` in `AgentLoop.swift`
5. Bump `mlx-swift-lm` to the new official version in `Package.swift`
