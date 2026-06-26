import Foundation
import MLX
import MLXLMCommon
import MLXRandom

/// DFlash block-based speculative decoder.
///
/// Port of `stream_generate` from z-lab/dflash (`dflash/model_mlx.py`). Produces a
/// token stream shaped like the upstream `generateTokens`, so the existing agent
/// generation loop can consume it unchanged.
enum DFlashSpeculativeDecoder {

    static func stream(
        runtime: DFlashRuntime,
        promptTokens: [Int],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        extraEOS: Set<Int>
    ) -> AsyncStream<TokenGeneration> {
        AsyncStream { continuation in
            let task = Task {
                run(
                    runtime: runtime, promptTokens: promptTokens, maxTokens: max(1, maxTokens),
                    temperature: temperature, topP: topP, extraEOS: extraEOS,
                    yield: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Core loop

    private static func run(
        runtime: DFlashRuntime,
        promptTokens: [Int],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        extraEOS: Set<Int>,
        yield: (TokenGeneration) -> Void
    ) {
        let target = runtime.target
        let draft = runtime.draft
        let layerIds = runtime.targetLayerIds
        let maskId = runtime.maskTokenId
        let eos = runtime.eosTokenIds.union(extraEOS)

        // Bind the draft to the target's (shared) embedding and LM head.
        draft.borrowedEmbed = { target.embed($0) }
        draft.borrowedLMHead = { target.applyLMHead($0) }
        draft.embedScale = 1.0

        let promptSize = promptTokens.count
        guard promptSize > 0 else { return }

        let targetCache = target.makeCache()
        let draftCache = draft.makeCache()
        let capture = DFlashGDNCapture()

        func sampleArray(_ logits: MLXArray) -> MLXArray {
            if temperature <= 0 {
                return logits.argMax(axis: -1).asType(.int32)
            }
            return MLXRandom.categorical(logits * (1.0 / temperature)).asType(.int32)
        }
        func sample(_ logits: MLXArray) -> [Int] {
            let ids = sampleArray(logits)
            eval(ids)
            return ids.asArray(Int.self)
        }

        var n = 0
        let prefillStart = Date()
        var promptTime: TimeInterval = 0
        var generationStart = Date()
        func finish(_ reason: GenerateStopReason) {
            yield(
                .info(
                    GenerateCompletionInfo(
                        promptTokenCount: promptSize,
                        generationTokenCount: n,
                        promptTime: promptTime,
                        generationTime: Date().timeIntervalSince(generationStart),
                        stopReason: reason)))
        }

        // Prefill, chunked to bound the per-timestep GatedDeltaNet graph (the upstream
        // generate path uses `prefillStepSize` for the same reason). DFlash needs the
        // target hidden states for *all* prompt positions, so we accumulate them.
        let prefillStep = 512
        var hiddenParts: [MLXArray] = []
        var lastLogits = MLXArray.zeros([1, 1, 1])
        var pos = 0
        while pos < promptSize {
            if Task.isCancelled { return }
            let end = min(pos + prefillStep, promptSize)
            let chunk = MLXArray(promptTokens[pos..<end].map { Int32($0) }).reshaped([1, end - pos])
            let (chunkLogits, chunkHidden) = target.forward(
                chunk, cache: targetCache, targetLayerIds: layerIds, captureGDN: nil)
            hiddenParts.append(chunkHidden)
            if end == promptSize {
                lastLogits = chunkLogits[0..., (end - pos - 1)..., 0...]
            }
            eval(chunkHidden, lastLogits)
            eval(targetCache)
            pos = end
        }
        var hidden = hiddenParts.count == 1 ? hiddenParts[0] : concatenated(hiddenParts, axis: 1)
        eval(hidden)

        promptTime = Date().timeIntervalSince(prefillStart)
        generationStart = Date()
        var token = sample(lastLogits)[0]
        n = 1
        yield(.token(token))
        if eos.contains(token) { finish(.stop); return }

        let blockSize = runtime.blockSize

        while n < maxTokens {
            if Task.isCancelled { return }
            let bs = min(blockSize, maxTokens - n + 1)
            if bs <= 1 { break }

            // Draft proposal: [last_token, mask, mask, ...].
            let blockVals = [Int32(token)] + Array(repeating: Int32(maskId), count: bs - 1)
            let block = MLXArray(blockVals).reshaped([1, bs])
            let draftLogits = draft(
                block, targetHidden: hidden, cache: draftCache, logitsStart: 1)

            // Keep the draft cache aligned to the verified prefix.
            let trimN = draftCache[0].offset - (promptSize + n - 1)
            if trimN > 0 {
                for c in draftCache { c.trim(trimN) }
            }
            let draftTokensArr = sampleArray(draftLogits)  // [1, bs-1]
            asyncEval(draftTokensArr)

            // Verify with the target. Build the verify input from the draft tokens as an
            // MLX op (no CPU read), so the draft and target passes pipeline — only one
            // sync per block (the `asArray` below), matching the reference.
            let tokenArr = MLXArray([Int32(token)]).reshaped([1, 1])
            let verifyInput = concatenated([tokenArr, draftTokensArr], axis: 1)  // [1, bs]
            let (verifyLogits, verifyHidden) = target.forward(
                verifyInput, cache: targetCache, targetLayerIds: layerIds, captureGDN: capture)
            let targetTokensArr = sampleArray(verifyLogits)  // [1, bs]
            asyncEval(targetTokensArr, verifyHidden)

            let draftTokens = draftTokensArr.asArray(Int.self)  // single sync point
            let targetTokens = targetTokensArr.asArray(Int.self)

            // Accept the longest matching prefix, then the first target token.
            var accepted = draftTokens.count
            for i in 0..<draftTokens.count where draftTokens[i] != targetTokens[i] {
                accepted = i
                break
            }
            var newTokens = Array(draftTokens[0..<accepted]) + [targetTokens[accepted]]
            if newTokens.count > maxTokens - n {
                newTokens = Array(newTokens[0..<(maxTokens - n)])
            }

            // Emit, stopping at EOS.
            var hitEOS = false
            for t in newTokens {
                yield(.token(t))
                n += 1
                if eos.contains(t) { hitEOS = true; break }
            }
            if let last = newTokens.last { token = last }
            if hitEOS { finish(.stop); return }

            // Roll the target cache back to the accepted prefix.
            let trim = bs - accepted - 1
            if trim > 0 {
                rollbackTarget(
                    cache: targetCache, isLinear: target.isLinear, records: capture.records,
                    accepted: accepted, trim: trim)
            }

            // Carry the accepted hidden states forward as the next draft context.
            // Async-eval cache/hidden so it overlaps the next block instead of stalling.
            hidden = verifyHidden[0..., ..<(accepted + 1), 0...]
            asyncEval([hidden] + targetCache.flatMap { $0.state } + draftCache.flatMap { $0.evalArrays })
        }

        finish(.length)
    }

    /// Mirror of `_GDNStateCapture.rollback`: trim the trimmable (full-attention)
    /// caches and replay GatedDeltaNet updates for the accepted prefix to restore
    /// the linear-attention caches.
    private static func rollbackTarget(
        cache: [KVCache], isLinear: [Bool], records: [DFlashGDNRecord], accepted: Int, trim: Int
    ) {
        for (i, c) in cache.enumerated() where !isLinear[i] {
            _ = c.trim(trim)
        }

        let n = accepted + 1
        for rec in records {
            let maskSlice = rec.mask.map { $0[0..., ..<n] }
            let (_, state) = dflashGatedDeltaUpdate(
                q: rec.q[0..., ..<n, 0..., 0...],
                k: rec.k[0..., ..<n, 0..., 0...],
                v: rec.v[0..., ..<n, 0..., 0...],
                a: rec.a[0..., ..<n, 0...],
                b: rec.b[0..., ..<n, 0...],
                aLog: rec.aLog,
                dtBias: rec.dtBias,
                state: rec.initState,
                mask: maskSlice)
            rec.cache[1] = state
            if rec.convKernelSize > 1 {
                rec.cache[0] = rec.convInput[0..., (accepted + 1)..<(accepted + rec.convKernelSize), 0...]
            }
        }
    }
}
