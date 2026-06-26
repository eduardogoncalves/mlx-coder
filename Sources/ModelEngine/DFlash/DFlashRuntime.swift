import Foundation
import MLX
import MLXLMCommon

/// Everything the DFlash speculative decoder needs at generation time. Holds MLX
/// modules (reference types sharing the target's weights), hence `@unchecked Sendable`.
public final class DFlashRuntime: @unchecked Sendable {
    let draft: DFlashDraftModel
    let target: DFlashTargetModel
    let targetLayerIds: [Int]
    let maskTokenId: Int
    let blockSize: Int
    /// EOS ids from the *target* model config (and tokenizer).
    let eosTokenIds: Set<Int>

    init(
        draft: DFlashDraftModel, target: DFlashTargetModel, targetLayerIds: [Int],
        maskTokenId: Int, blockSize: Int, eosTokenIds: Set<Int>
    ) {
        self.draft = draft
        self.target = target
        self.targetLayerIds = targetLayerIds
        self.maskTokenId = maskTokenId
        self.blockSize = blockSize
        self.eosTokenIds = eosTokenIds
    }
}
