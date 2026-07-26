// Sources/AgentCore/AgentLoop+Generation.swift
// Response generation — tokenization, streaming, and think-block rendering.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

extension AgentLoop {

    /// Generate a response from the model using the current conversation history.
    /// Returns the response text, the streaming writer (for streamed tool calls),
    /// and whether the response began inside a pre-filled `<think>` block.
    func generateResponse() async throws -> (text: String, writer: StreamingToolCallWriter, startedThinking: Bool, turnStats: (promptTokens: Int, completionTokens: Int, elapsed: TimeInterval, tokensPerSecond: Double?)?, finishReason: String?, thinkingBudgetBreached: Bool) {
        // Consumed unconditionally (even on the remote path, which ignores it)
        // so a breach on a previous local turn can never leak a stale
        // suppression into some later turn after the backend changes.
        let suppressThinkingThisTurn = forceThinkingOffNextTurn
        forceThinkingOffNextTurn = false

        // Route online backends through their HTTP client — local MLX path below
        // assumes a loaded ModelContainer, which online providers never produce.
        if backend.isOnline {
            return try await generateResponseViaRemote()
        }

        // Apply context transforms (snapshot — does not mutate stored history)
        var transformedMessages = history.messages
        for (index, transform) in contextTransforms.enumerated() {
            let before = transformedMessages.count
            transformedMessages = await transform(transformedMessages)
            let after = transformedMessages.count
            if after != before {
                await hooks.emit(.contextTransformApplied(transformIndex: index, messagesBefore: before, messagesAfter: after))
            }
        }
        // Consume pending images (cleared here so they apply to this turn only).
        // AgentLoop is an actor so there is no concurrent access risk on pendingImages.
        let imageURLs = pendingImages
        pendingImages = []

        let isGemma4Model = modelPath.lowercased().contains("gemma-4")
        let dialect = toolCallDialect
        // Use the model container to prepare input and generate.
        // Only image turns need the processor path; plain text stays on the direct ChatML path.
        let modelContainer = try requireLoadedModelContainer()
        let isVLM = await modelContainer.isVLM
        // Some local checkpoints report VLM capability but ship without processor metadata.
        // In that case, forcing processor.prepare() on text-only turns can crash at runtime.
        let hasProcessorConfig = modelHasProcessorConfig(modelPath)
        // For VLMs with processor metadata, prefer the processor path even for text-only
        // turns. Some VLM checkpoints require processor-driven preparation to ensure
        // auxiliary tensors (e.g. image/video masks) stay consistent with prompt length.
        let shouldUseProcessorPath = isVLM && hasProcessorConfig
        let enableThinking = thinkingLevel != .fast && !isGemma4Model && !suppressThinkingThisTurn
        // The budget the per-token loop enforces this turn. When thinking was
        // forced off (a breach on the prior turn), use `.fast`'s budget (0)
        // rather than the configured level's — if the model ignores
        // `enableThinking: false` and starts a think block anyway, it should
        // be cut off almost immediately, not given the full budget for a
        // level that was just deliberately suppressed.
        let thinkingBudgetTokens = suppressThinkingThisTurn ? ThinkingLevel.fast.budgetTokens : thinkingLevel.budgetTokens
        let chatML = history.formatChatML(messages: transformedMessages, enableThinking: enableThinking)
        // Template messages for applyChatTemplate() — model-native prompt formatting.
        let templateMessages: [[String: any Sendable]] = transformedMessages.map { msg in
            ["role": msg.role.rawValue, "content": msg.wireContent]
        }

        // For the processor path, capture the Sendable message data to rebuild Chat.Message inside perform.
        // Chat.Message contains CIImage and is not Sendable, so we reconstruct it in the closure.
        // We use the last user-message index rather than content equality to robustly identify which
        // message should receive the image attachments.
        let vlmMessageData: [(role: String, content: String)]? = shouldUseProcessorPath ?
            transformedMessages.map { ($0.role.rawValue, $0.content) }
            : nil
        let vlmLastUserIndex: Int? = shouldUseProcessorPath ?
            transformedMessages.indices.last(where: { transformedMessages[$0].role == .user })
            : nil

        // Prompt preparation starts before inference/token streaming.
        frontend.emit(.tokenProcessingActivity(.started))

        // Pre-generation safety guard: if the formatted context exceeds the practical
        // safe limit for MLX tensor allocation, throw a *recoverable* error rather
        // than letting the C++ reshape assertion fire (which calls fatalError and kills
        // the process).  The caller's retry loop will trigger context compaction.
        //
        // Threshold: 400 000 chars ≈ 100 000 tokens at ~4 chars/token — well above any
        // model's real context window.  A context this large means something slipped
        // past the condensation and compaction layers.
        let maxSafeContextChars = 400_000
        guard chatML.count <= maxSafeContextChars else {
            frontend.emit(.tokenProcessingActivity(.ended))
            throw NSError(
                domain: "AgentLoop",
                code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Context too large (\(chatML.count) chars, limit \(maxSafeContextChars)). " +
                        "Compaction will run before the next attempt."
                ]
            )
        }

        let draftModel = self.draftModel
        let promptCache = self.promptCache
        let promptCacheStats = self.promptCacheStats
        let result = try await modelContainer.perform { [currentGenerationConfig, frontend, chatML, templateMessages, enableThinking, thinkingBudgetTokens, imageURLs, vlmMessageData, vlmLastUserIndex, shouldUseProcessorPath, isVLM, dialect, draftModel, promptCache, promptCacheStats] (context: ModelContext) in
            if Task.isCancelled { throw CancellationError() }
            var hasTokenProcessingEnded = false
            var hasGenerationStarted = false
            // Tracks an open `.thinkingActivity(.started)` with no matching `.ended`
            // yet. Declared here (rather than next to beginThinkingIfNeeded/
            // endThinkingIfNeeded below) so the defer can close it out — see its use there.
            var hasOpenThinkingActivity = false
            // Updated by the text-path template application below; VLM paths leave it at enableThinking.
            var actuallyStartedThinking = enableThinking

            // Persistent cross-turn KV cache bookkeeping (plain-text path only).
            // These stay nil on every other path, so the defer below is a no-op there.
            // `persistentCache` is the cache selected for THIS turn (reused-and-trimmed
            // or freshly created); `promptTokensForCache` is the full prompt token list
            // used to update the store after a successful generation.
            var persistentCache: [KVCache]? = nil
            var promptTokensForCache: [Int]? = nil
            var cacheCommitted = false
            // New tokens the model actually processes this turn (suffix since cache reuse).
            // Set inside the caching block; falls back to input.text.tokens.size for
            // non-caching paths (VLM, speculative). Used for the spinner ↑ count and stats.
            var turnInputTokenCount: Int = 0

            defer {
                // If generation threw or was cancelled mid-stream while a think block
                // was still open, the normal close path (parser.flush below) never
                // runs — close it here so `.generationActivity(.ended)` below always
                // has a matching `.thinkingActivity(.ended)` in front of it. Without
                // this, SwiftCoderTUIFrontend defers clearing "isGenerating" forever
                // waiting for an `.ended` that will never arrive (see its
                // `.generationActivity(.ended)` handler), leaving the TUI stuck
                // thinking a turn is still in flight.
                if hasOpenThinkingActivity {
                    frontend.emit(.thinkingActivity(.ended))
                    hasOpenThinkingActivity = false
                }
                if hasGenerationStarted {
                    frontend.emit(.generationActivity(.ended))
                }
                if !hasTokenProcessingEnded {
                    frontend.emit(.tokenProcessingActivity(.ended))
                }
                // If a persistent cache was selected for this turn but never committed
                // (generation threw or was cancelled mid-stream), drop the store so a
                // partially-filled / corrupt cache is never reused on the next turn.
                if persistentCache != nil && !cacheCommitted {
                    promptCache.invalidate(reason: "generation did not complete")
                }
            }

            // Cross-turn prompt caching only applies on the safe plain-text path:
            // non-VLM (so no processor-driven prep), no speculative draft model, and
            // no TurboQuant cache. On every other path we drop any cache left over
            // from a previous plain-text turn so a prompt shape mismatch can't reuse it.
            let persistentCachingApplies = !isVLM
                && draftModel == nil
                && currentGenerationConfig.turboQuantBits == nil
            if !persistentCachingApplies {
                promptCache.invalidate(reason: "path does not support caching")
            }

            // Processor path: for image turns and model families that require processor-driven
            // prompt preparation, use UserInput +
            // processor.prepare so model-specific prompt formatting and tensor shapes are respected.
            // Fallback text-only path tokenizes ChatML directly.
            let tokenizer = context.tokenizer

            // Resolve generation parameters up front — they are needed both for the
            // token stream below and, on the plain-text path, for sizing a fresh KV
            // cache via `model.newCache(parameters:)`.
            var generationParameters = currentGenerationConfig.generateParameters
            if shouldUseProcessorPath {
                generationParameters.repetitionPenalty = nil
                generationParameters.presencePenalty = nil
                generationParameters.frequencyPenalty = nil
            }
            // Strip kvBits so TokenIterator never calls maybeQuantizeKVCache, which
            // would replace KVCacheSimple with QuantizedKVCache mid-generation.
            // QuantizedKVCache.update() is a fatalError in the updated mlx-swift-lm:
            // models that call cache.update() directly (Gemma2, DeepseekV3, etc.)
            // crash on the second generated token once the cache is promoted.
            // TurboQuant and cross-turn caching manage compression independently.
            generationParameters.kvBits = nil

            let input: LMInput
            if let messageData = vlmMessageData {
                // Reconstruct Chat.Message inside the closure (Chat.Message is not Sendable).
                let chatMessages: [Chat.Message] = messageData.enumerated().map { idx, msg in
                    let (role, content) = msg
                    switch role {
                    case "system":    return .system(content)
                    case "assistant": return .assistant(content)
                    case "tool":      return .tool(content)
                    default:          // user
                        // Use index-based identification to robustly find the last user message.
                        let userImages: [UserInput.Image] = (idx == vlmLastUserIndex) ? imageURLs.map { .url($0) } : []
                        return .user(content, images: userImages)
                    }
                }
                let userInput = UserInput(chat: chatMessages)
                do {
                    let prepared = try await context.processor.prepare(input: userInput)
                    if prepared.text.tokens.size > 0 {
                        input = prepared
                    } else if imageURLs.isEmpty {
                        let tokens = try AgentLoop.encodeNonEmptyTokens(
                            primaryText: chatML,
                            fallbackTexts: ["hi", "a"],
                            using: tokenizer.encode(text:)
                        )
                        input = try AgentLoop.makeSafeTextLMInput(tokens: tokens)
                    } else {
                        throw NSError(
                            domain: "AgentLoop",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Processor produced empty prompt tokens for an image input."]
                        )
                    }
                } catch {
                    // If processor preparation fails on a text-only turn, fall back to
                    // direct tokenization so the user still gets a response.
                    guard imageURLs.isEmpty else { throw error }
                    let tokens = try AgentLoop.encodeNonEmptyTokens(
                        primaryText: chatML,
                        fallbackTexts: ["hi", "a"],
                        using: tokenizer.encode(text:)
                    )
                    input = try AgentLoop.makeSafeTextLMInput(tokens: tokens)
                }
            } else {
                // Use the model's native chat template when available (reads chat_template from
                // tokenizer_config.json). This handles non-ChatML models (GLM-4, etc.) correctly.
                // Falls back to the hand-written ChatML formatter when the template is missing or
                // errors (e.g. unsupported role in the template's Jinja).
                let additionalCtx: [String: any Sendable] = ["enable_thinking": enableThinking]
                let tokens: [Int]
                if let ids = try? tokenizer.applyChatTemplate(
                    messages: templateMessages, tools: nil, additionalContext: additionalCtx),
                    !ids.isEmpty {
                    tokens = ids
                    // Detect whether the template actually opened a <think> block so that
                    // StreamParser and the upstream tool-call parser are set correctly.
                    // Qwen3's template inserts <think>\n when enable_thinking: true; other
                    // models ignore the variable and never emit <think>.
                    let tailIds = Array(ids.suffix(12))
                    let decodedTail = tokenizer.decode(tokenIds: tailIds, skipSpecialTokens: false)
                    actuallyStartedThinking = decodedTail.contains("<think>")
                } else {
                    tokens = try AgentLoop.encodeNonEmptyTokens(
                        primaryText: chatML,
                        fallbackTexts: ["hi", "a"],
                        using: tokenizer.encode(text:))
                    actuallyStartedThinking = enableThinking
                }
                if isVLM {
                    // VLM checkpoint without processor metadata: still text-only here,
                    // but persistent caching stays disabled for this family.
                    input = try AgentLoop.makeSafeTextLMInput(tokens: tokens)
                } else if persistentCachingApplies {
                    // Plain-text LLM path — the only path that participates in
                    // cross-turn prompt caching. Diff this turn's prompt against the
                    // tokens the persisted cache physically holds, trim the cache back
                    // to the shared prefix, and feed ONLY the new suffix. This mirrors
                    // mlx_lm.server / lmstudio mlx-engine: the default prefill does not
                    // skip already-cached tokens on its own, so the caller must slice
                    // the input and trim the cache to `offset == common`.
                    promptTokensForCache = tokens

                    let hasCache = promptCache.cache != nil
                    let cacheIsTrimmable = promptCache.cache.map(canTrimPromptCache) ?? false
                    // Use max offset across all layers because hybrid models (e.g.
                    // Qwen3.5) mix KVCacheSimple (which updates offset per token) with
                    // MambaCache (which never updates its offset property — always 0,
                    // since Mamba layers store state via subscripts, not update(keys:values:)).
                    // Using first?.offset would return 0 for such models.
                    let liveOffset = promptCache.cache?.map(\.offset).max() ?? 0

                    let decision = AgentLoop.computePromptCacheDecision(
                        cachedTokens: promptCache.cachedTokens,
                        promptTokens: tokens,
                        cacheOffset: liveOffset,
                        hasCache: hasCache,
                        cacheIsTrimmable: cacheIsTrimmable
                    )

                    if promptCacheStats {
                        frontend.emitStatus(
                            "[PromptCache] decision: cached=\(promptCache.cachedTokens.count) "
                            + "prompt=\(tokens.count) liveOffset=\(liveOffset) "
                            + "common=\(decision.common) toTrim=\(decision.toTrim) "
                            + "trimmable=\(cacheIsTrimmable) hasCache=\(hasCache) "
                            + "-> \(decision.reuseCache ? "reuse" : "fresh") "
                            + "ckpt=\(promptCache.checkpointTokens.count)"
                        )
                    }

                    // Phase 1: select the cache and reuseStart.
                    // reuseStart is the index into `tokens` from which we still need
                    // to prefill; tokens[..<reuseStart] are already in the selected cache.
                    var reuseStart: Int = 0

                    if decision.reuseCache, let existing = promptCache.cache {
                        if decision.toTrim > 0 {
                            trimPromptCache(existing, numTokens: decision.toTrim)
                        }
                        // After trimming, every attention layer's offset must equal
                        // the shared prefix length. MambaCache (hybrid models like
                        // Qwen3.5) never updates its offset property (stays 0), so
                        // we check the max across all layers — which reflects the
                        // KVCacheSimple (attention) layers' actual physical state.
                        let offsetsConsistent = (existing.map { $0.offset }.max() ?? 0) == decision.common
                        if offsetsConsistent {
                            persistentCache = existing
                            reuseStart = decision.common
                            if promptCacheStats {
                                frontend.emitStatus(
                                    "[PromptCache] restore: cached_tokens=\(decision.common) "
                                    + "uncached_tokens=\(tokens.count - decision.common)"
                                )
                            }
                        } else {
                            let actualOffsets = existing.prefix(8).map { $0.offset }
                            let fresh = context.model.newCache(parameters: generationParameters)
                            persistentCache = fresh
                            reuseStart = 0
                            frontend.emitStatus(
                                "[PromptCache] initialized (offset mismatch after trim — "
                                + "re-prefilling \(tokens.count) tok) offsets=\(actualOffsets)"
                            )
                        }
                    } else if hasCache && !cacheIsTrimmable && decision.toTrim > 0 {
                        // Diverged on a non-trimmable hybrid model (e.g. Qwen3.5).
                        // Try the mlx-engine checkpoint: a snapshot taken before the
                        // volatile tail tokens, which may still be a pure prefix of the
                        // new prompt even after thinking-block re-rendering.
                        let fallback = AgentLoop.computeCheckpointFallback(
                            checkpointTokens: promptCache.checkpointTokens,
                            promptTokens: tokens
                        )
                        if fallback.useCheckpoint, let checkpoint = promptCache.checkpointCache {
                            // Copy-on-restore: clone the checkpoint so it stays valid
                            // even if this generation later fails mid-stream.
                            let restored = checkpoint.map { $0.copy() }
                            let restoredOffset = restored.map(\.offset).max() ?? 0
                            if restoredOffset == fallback.prefillFrom {
                                persistentCache = restored
                                reuseStart = fallback.prefillFrom
                                if promptCacheStats {
                                    frontend.emitStatus(
                                        "[PromptCache] checkpoint restore: "
                                        + "cached_tokens=\(fallback.prefillFrom) "
                                        + "uncached_tokens=\(tokens.count - fallback.prefillFrom)"
                                    )
                                }
                            } else {
                                // Checkpoint offset mismatch — discard the checkpoint and
                                // fall back to a full re-prefill.
                                frontend.emitStatus(
                                    "[PromptCache] checkpoint offset mismatch "
                                    + "(offset \(restoredOffset), expected \(fallback.prefillFrom))"
                                    + " — discarding"
                                )
                                promptCache.checkpointCache = nil
                                promptCache.checkpointTokens = []
                                let fresh = context.model.newCache(parameters: generationParameters)
                                persistentCache = fresh
                                reuseStart = 0
                            }
                        } else {
                            // Checkpoint not usable — full re-prefill. The fresh cache
                            // will be committed and checkpointed so the next turn can
                            // benefit if the prompt grows monotonically.
                            let lcp = AgentLoop.longestCommonPrefixLength(
                                promptCache.checkpointTokens, tokens)
                            let ckptInfo = promptCache.checkpointTokens.isEmpty
                                ? ""
                                : " (checkpoint unusable:"
                                    + " ckpt=\(promptCache.checkpointTokens.count) lcp=\(lcp))"
                            frontend.emitStatus(
                                "[PromptCache] non-trimmable cache diverged "
                                + "(common \(decision.common), would trim \(decision.toTrim)) "
                                + "— re-prefilling full prompt (\(tokens.count) tok)\(ckptInfo)"
                            )
                            let fresh = context.model.newCache(parameters: generationParameters)
                            persistentCache = fresh
                            reuseStart = 0
                        }
                    } else {
                        // First turn, divergent first token, or other non-reuse case:
                        // prefill the full prompt into a fresh cache. The cache is always
                        // kept for future reuse — pure-prefix extension is valid for any
                        // cache type (including non-trimmable Mamba/hybrid), so we never
                        // discard the cache here.
                        let fresh = context.model.newCache(parameters: generationParameters)
                        persistentCache = fresh
                        reuseStart = 0
                        if promptCacheStats {
                            frontend.emitStatus(
                                "[PromptCache] initialized (prefilling \(tokens.count) tok)"
                            )
                        }
                    }

                    // Phase 2: two-phase prefill + checkpoint snapshot (non-trimmable
                    // caches only, mlx-engine style). For trimmable models, trimming
                    // already handles divergence — keep their existing single-phase path
                    // where input = tokens[reuseStart...].
                    //
                    // Idea: bulk-prefill the stable portion of the suffix (everything
                    // except the last `checkpointTailTokens`), snapshot the cache state
                    // BEFORE the volatile generation-header tail is fed, then hand only
                    // the tail to the main generateTokens call. On the next turn, if the
                    // re-rendered prompt diverges inside that tail region (e.g. a thinking
                    // block is stripped), the checkpoint is still a pure prefix and can be
                    // restored without trimming — bypassing the Mamba constraint.
                    let selectedCacheNonTrimmable = !canTrimPromptCache(persistentCache!)
                    let suffix = Array(tokens[reuseStart...])
                    turnInputTokenCount = suffix.count
                    if selectedCacheNonTrimmable
                        && suffix.count > PromptCacheStore.checkpointTailTokens {
                        let bulkTokens = Array(
                            suffix.dropLast(PromptCacheStore.checkpointTailTokens))
                        let tailTokens = Array(
                            suffix.suffix(PromptCacheStore.checkpointTailTokens))
                        // Bulk-prefill into the selected cache. `TokenIterator.init`
                        // calls model.prepare() (feeds tokens[0..N-2] through the model)
                        // then step() (feeds the last token), advancing the cache by
                        // exactly bulkTokens.count positions. We discard the iterator;
                        // only the cache mutation matters.
                        // Uses `init(input:model:cache:parameters:)` so kvBits /
                        // prefillStepSize from generationParameters are respected,
                        // matching the settings of the main generateTokens call.
                        // Wrap in the sync withError so a C++ MLX assertion surfaces
                        // as a thrown Swift error rather than aborting the process.
                        let bulkInput = try AgentLoop.makeSafeTokenLMInput(
                            tokens: bulkTokens)
                        _ = try withError {
                            try TokenIterator(
                                input: bulkInput,
                                model: context.model,
                                cache: persistentCache,
                                parameters: generationParameters
                            )
                        }
                        // Snapshot the cache state at (promptLen − tailMargin),
                        // before the volatile tail is prefilled.
                        promptCache.checkpointCache = persistentCache!.map { $0.copy() }
                        promptCache.checkpointTokens = Array(
                            tokens.prefix(
                                tokens.count - PromptCacheStore.checkpointTailTokens))
                        if promptCacheStats {
                            frontend.emitStatus(
                                "[PromptCache] checkpoint saved at"
                                + " \(promptCache.checkpointTokens.count) tok"
                                + " (tail margin \(PromptCacheStore.checkpointTailTokens))"
                            )
                        }
                        input = try AgentLoop.makeSafeTokenLMInput(tokens: tailTokens)
                    } else {
                        // Trimmable cache (single-phase) or suffix too small to
                        // checkpoint. Keep the existing checkpoint — it is still a valid
                        // prefix and remains usable on the next turn.
                        input = try AgentLoop.makeSafeTokenLMInput(tokens: suffix)
                    }
                } else {
                    // Text model on a non-cacheable path (speculative decoding or
                    // TurboQuant): keep legacy behavior — prefill the full prompt.
                    input = try AgentLoop.makeSafeTokenLMInput(tokens: tokens)
                    turnInputTokenCount = tokens.count
                }
            }

            // Clean up stale .tmp files from previous crashed/interrupted sessions.
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mlx-coder-streaming")
            try? FileManager.default.removeItem(at: tmpDir)
            // Streaming writer: streams tool call content to .tmp files during generation
            let writer = StreamingToolCallWriter(
                toolCallOpen: dialect.toolCallOpen,
                toolCallClose: dialect.toolCallClose,
                parsesJSONBody: dialect.supportsStreamingJSONContent,
                onStatusChange: { message in
                    let severity: StatusMessage.Severity = message.hasPrefix(StreamingToolCallWriter.tmpFileStatusPrefix)
                        ? .info
                        : .debug
                    frontend.emit(.status(StatusMessage(message, severity: severity)))
                }
            )

            var rawResponseText = ""
            // StreamParser handles the think-block state machine and emits the
            // correct AgentEvents. startsThinking mirrors enableThinking because
            // the "<think>" open tag is pre-filled in the prompt when thinking is
            // enabled — the model output begins *inside* the think block.
            var parser = StreamParser(
                openTag: ToolCallPattern.thinkOpen,
                closeTag: ToolCallPattern.thinkClose,
                startsThinking: actuallyStartedThinking
            )
            // VLM and other non-caching paths don't set turnInputTokenCount; fall back
            // to the raw input size (full prompt — no cache on those paths anyway).
            if turnInputTokenCount == 0 { turnInputTokenCount = input.text.tokens.size }
            frontend.emit(.promptTokensKnown(turnInputTokenCount))
            hasTokenProcessingEnded = true
            frontend.emit(.tokenProcessingActivity(.ended))
            hasGenerationStarted = true
            frontend.emit(.generationActivity(.started))

            func beginThinkingIfNeeded() {
                guard !hasOpenThinkingActivity else { return }
                frontend.emit(.thinkingActivity(.started))
                hasOpenThinkingActivity = true
            }

            func endThinkingIfNeeded() {
                if !hasOpenThinkingActivity {
                    // Keep lifecycle ordering strict even if the stream closes
                    // an implicit think block before any visible think chunk.
                    beginThinkingIfNeeded()
                }
                frontend.emit(.thinkingActivity(.ended))
                hasOpenThinkingActivity = false
            }

            // Build TurboQuant KV cache when enabled.
            // KVCacheSimple layers are replaced with TurboQuantKVCache (fill phase);
            // sliding-window (RotatingKVCache) and other layers are preserved.
            // TurboQuantKVCache auto-compresses on the first single-token update
            // after prefill, so no upstream changes are required.
            let tqCache: [KVCache]? = currentGenerationConfig.turboQuantBits.map { bits in
                makeTurboQuantCaches(
                    model: context.model,
                    parameters: generationParameters,
                    keyBits: bits,
                    valueBits: bits
                )
            }

            // The cache passed to the iterator: the persistent cross-turn cache when
            // it applies (already trimmed + suffix-sliced above), else the TurboQuant
            // cache, else nil (fresh per-call cache built by the iterator). These are
            // mutually exclusive — persistent caching requires `turboQuantBits == nil`.
            let generationCache: [KVCache]? = persistentCache ?? tqCache

            // For correct streaming detokenization
            var segmentTokens = [Int]()
            var segment = ""
            // Full list of generated token ids in order. `segmentTokens` is reset on
            // newlines for detokenization, so it cannot be used for cache bookkeeping;
            // this collects every id so the store can record prompt + generated tokens.
            var generatedTokenIds = [Int]()
            // Per-round stats captured from the terminal `.info` event and returned to
            // the caller for accumulation across tool-call rounds within one turn.
            var capturedTurnStats: (promptTokens: Int, completionTokens: Int, elapsed: TimeInterval, tokensPerSecond: Double?)? = nil

            // Thinking-token budget enforcement (see ThinkingBudget.swift).
            // Counts generated tokens while `parser.isThinking` is true — real
            // token ids from the stream, not decoded characters, since the
            // budget itself is denominated in tokens. Reset per call (i.e. per
            // generation round), matching the fact that `budgetTokens` is a
            // per-turn allowance.
            var thinkingTokenCount = 0
            // Set when the budget is breached and the think block is force-
            // closed; threaded back to `AgentLoop.swift` through the return
            // tuple exactly like `finishReason`, since this Sendable closure
            // cannot touch `self.steeringQueue` directly.
            var thinkingBudgetBreached = false

            // Build the set of stop-token ids we must intercept in the stream.
            // `buildStopTokenIds` in MLXLMCommon/Evaluate.swift is private, so we
            // replicate the same logic here. With includeStopToken: true, the stop
            // token arrives as a final .token(id) in the stream and must be appended
            // to generatedTokenIds (so the cache mirrors the physical state) but must
            // NOT enter text processing — otherwise the EOS text leaks to the UI.
            // unknownTokenId is also treated as a stop by the iterator loop.
            var stopTokenIds: Set<Int> = context.configuration.eosTokenIds
            if let eosId = tokenizer.eosTokenId {
                stopTokenIds.insert(eosId)
            }
            for extraToken in context.configuration.extraEOSTokens {
                if let id = tokenizer.convertTokenToId(extraToken) {
                    stopTokenIds.insert(id)
                }
            }
            if let unknownId = tokenizer.unknownTokenId {
                stopTokenIds.insert(unknownId)
            }

            // Build the token stream inside `withError` so a C++ MLX failure
            // (e.g. the "[reshape] Cannot infer the shape of an empty array"
            // assertion that fires while loading the prompt into the penalty
            // ring during TokenIterator construction) surfaces as a thrown Swift
            // `MLXError` instead of the library's default `fatalError`, which
            // would kill the whole process. The streaming child task that
            // `generateTokens` spawns is created within this scope and inherits
            // the task-local handler, so per-token MLX failures are likewise
            // prevented from aborting the process. Surfaced errors flow up to the
            // caller's retry/compaction loop for graceful recovery.
            let tokenStream: AsyncStream<TokenGeneration> = try withError {
                if let draftModel {
                    // Speculative-decoding path: never uses persistent caching, leave
                    // includeStopToken at the default (false) to preserve existing behaviour.
                    return try MLXLMCommon.generateTokens(
                        input: input,
                        cache: generationCache,
                        parameters: generationParameters,
                        context: context,
                        draftModel: draftModel.model,
                        numDraftTokens: currentGenerationConfig.numDraftTokens
                    )
                } else {
                    // Plain-text persistent-cache path: request the stop token so the
                    // iterator emits it as the final .token(id). This ensures the cache
                    // physically holds prompt + response + EOS, matching `cachedTokens`
                    // after commit, so the next turn's toTrim math stays zero for a pure
                    // prefix extension.
                    return try MLXLMCommon.generateTokens(
                        input: input,
                        cache: generationCache,
                        parameters: generationParameters,
                        context: context,
                        includeStopToken: true
                    )
                }
            }
            tokenLoop: for await item in tokenStream {
                if Task.isCancelled {
                    throw CancellationError()
                }

                switch item {
                case .token(let id):
                    // Always record the token id for cache bookkeeping — including the
                    // stop token, so cachedTokens mirrors the physical cache depth.
                    generatedTokenIds.append(id)

                    // Stop tokens (EOS / unknown) must not enter text processing:
                    // the iterator feeds them through the cache before emitting (so the
                    // physical cache advances), but their decoded text (e.g. "<|im_end|>")
                    // must never appear in the UI. Skip all text paths for stop ids.
                    if stopTokenIds.contains(id) {
                        continue
                    }

                    segmentTokens.append(id)
                    let newSegment = tokenizer.decode(tokenIds: segmentTokens, skipSpecialTokens: false)

                    // Skip yielding if incomplete multi-byte sequence
                    if newSegment.last == "\u{fffd}" {
                        continue
                    }

                    let newText = String(newSegment.suffix(newSegment.count - segment.count))
                    rawResponseText += newText

                    if newText.hasSuffix("\n") {
                        if let lastToken = segmentTokens.last {
                            segmentTokens = [lastToken]
                            segment = tokenizer.decode(tokenIds: segmentTokens, skipSpecialTokens: false)
                        }
                    } else {
                        segment = newSegment
                    }

                    // Captured before feeding the parser: whether this token's
                    // text was generated while still inside the think block.
                    // Used below to count thinking tokens toward the budget —
                    // captured pre-feed (rather than post-feed) so the token
                    // that carries the closing `</think>` tag itself still
                    // counts as the last thinking token, not the first
                    // response token.
                    let wasThinkingBeforeFeed = parser.isThinking

                    // Route each token through the think-block parser. Thinking tokens
                    // are emitted directly; response tokens flow through the tool-call
                    // writer so it can detect <tool_call> blocks without being confused
                    // by reasoning content.
                    for event in parser.feed(newText) {
                        switch event {
                        case .thinkingActivity(let lifecycle):
                            switch lifecycle {
                            case .started:
                                beginThinkingIfNeeded()
                            case .ended:
                                endThinkingIfNeeded()
                            }
                        case .thinkingChunk(let chunk):
                            beginThinkingIfNeeded()
                            // Don't stop the spinner during thinking: the spinner
                            // should keep animating with "Thinking…" label while
                            // reasoning tokens stream in. Stopping it here (before
                            // the TUI consumer processes the chunk) would tear down
                            // the footer rendering state before any think line is
                            // visible, causing all chunks to appear batched at the end.
                            frontend.emit(.thinkingChunk(chunk))
                        case .assistantTextChunk(let chunk):
                            if hasOpenThinkingActivity {
                                endThinkingIfNeeded()
                            }
                            let result = writer.process(chunk)
                            if !result.displayText.isEmpty {
                                frontend.emit(.assistantTextChunk(result.displayText))
                            }
                        default:
                            break
                        }
                    }

                    // Thinking-token budget enforcement (see ThinkingBudget.swift).
                    // Placed after the generatedTokenIds append / rawResponseText
                    // bookkeeping above and after this token's parser events have
                    // already been emitted to the frontend, so breaking out below
                    // never corrupts KV-cache accounting or drops an already-
                    // decided event. On breach we don't throw (that would abort
                    // the whole turn) and don't touch `self.steeringQueue` (this
                    // closure can't) — we just stop consuming the stream here;
                    // `parser.flush(closeUnterminatedThinkingBlock: true)` below
                    // then closes the think block exactly as it would for a
                    // naturally-ending stream, and the breach is threaded back to
                    // `AgentLoop.swift` through the return tuple.
                    if wasThinkingBeforeFeed {
                        thinkingTokenCount += 1
                    }
                    if AgentLoop.shouldStopThinking(
                        thinkingTokensSoFar: thinkingTokenCount,
                        budgetTokens: thinkingBudgetTokens,
                        isThinking: parser.isThinking
                    ) {
                        thinkingBudgetBreached = true
                        break tokenLoop
                    }

                    // Yield to the Swift cooperative scheduler so the consumer task
                    // (SwiftCoderTUIFrontend) can render the events we just emitted
                    // before we generate the next token. Without this yield, the
                    // scheduler may not interleave the consumer between token iterations
                    // and all events would appear batched at the end of generation.
                    await Task.yield()
                case .info(let info):
                    // Defer emitting the stats line until after `parser.flush()`
                    // below. The flush can still release the final buffered
                    // assistant text (the last streamed line), and emitting the
                    // stats here would order it — and the caller's subsequent
                    // "Turn complete." status — ahead of that trailing line.
                    capturedTurnStats = (
                        promptTokens: turnInputTokenCount,
                        completionTokens: info.generationTokenCount,
                        elapsed: info.generateTime,
                        tokensPerSecond: info.tokensPerSecond
                    )
                }
            }

            // Flush any remaining buffered state in the parser
            for event in parser.flush(closeUnterminatedThinkingBlock: true) {
                switch event {
                case .thinkingActivity(let lifecycle):
                    switch lifecycle {
                    case .started:
                        beginThinkingIfNeeded()
                    case .ended:
                        endThinkingIfNeeded()
                    }
                case .thinkingChunk(let chunk):
                    beginThinkingIfNeeded()
                    frontend.emit(.thinkingChunk(chunk))
                case .assistantTextChunk(let chunk):
                    if hasOpenThinkingActivity {
                        endThinkingIfNeeded()
                    }
                    let result = writer.process(chunk)
                    if !result.displayText.isEmpty {
                        frontend.emit(.assistantTextChunk(result.displayText))
                    }
                default:
                    break
                }
            }


            // Generation completed successfully — persist the cache for the next
            // turn. The cache now physically holds prompt + generated tokens (including
            // the stop token, since includeStopToken: true feeds it through the cache
            // before the stream emits it). `cachedTokens` must mirror that exact
            // sequence for the next turn's prefix diff to be correct.
            // `cacheCommitted` disarms the defer's invalidate-on-failure guard.
            if let cache = persistentCache, let promptTokens = promptTokensForCache {
                promptCache.cache = cache
                promptCache.cachedTokens = promptTokens + generatedTokenIds
                cacheCommitted = true
                let physicalOffset = cache.map { $0.offset }.max() ?? 0
                let recorded = promptCache.cachedTokens.count
                let mismatch = physicalOffset != recorded
                if mismatch {
                    frontend.emitStatus(
                        "MISMATCH [PromptCache] committed: recorded=\(recorded) "
                        + "physicalOffset=\(physicalOffset) "
                        + "(prompt \(promptTokens.count) + generated \(generatedTokenIds.count))"
                    )
                } else if promptCacheStats {
                    frontend.emitStatus(
                        "[PromptCache] committed: recorded=\(recorded) "
                        + "physicalOffset=\(physicalOffset) "
                        + "(prompt \(promptTokens.count) + generated \(generatedTokenIds.count))"
                    )
                }
            }

            // Strip EOS/stop strings that may have leaked into the decoded text.
            // Use the model's actual stop strings rather than the hardcoded <|im_end|>
            // so non-ChatML models (GLM-4, etc.) are cleaned up correctly.
            var eosStrings = context.configuration.extraEOSTokens
            if let eosStr = tokenizer.eosToken { eosStrings.insert(eosStr) }
            for eos in eosStrings where !eos.isEmpty {
                rawResponseText = rawResponseText.replacingOccurrences(of: eos, with: "")
            }
            rawResponseText = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)

            return (text: rawResponseText, writer: writer, startedThinking: actuallyStartedThinking, turnStats: capturedTurnStats, finishReason: nil as String?, thinkingBudgetBreached: thinkingBudgetBreached)
        }

        return result
    }
}
