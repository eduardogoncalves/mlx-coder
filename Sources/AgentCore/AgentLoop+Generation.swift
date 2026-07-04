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
    func generateResponse() async throws -> (text: String, writer: StreamingToolCallWriter, startedThinking: Bool) {
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
        let enableThinking = thinkingLevel != .fast && !isGemma4Model
        let chatML = history.formatChatML(messages: transformedMessages, enableThinking: enableThinking)

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
        let result = try await modelContainer.perform { [currentGenerationConfig, frontend, chatML, imageURLs, vlmMessageData, vlmLastUserIndex, shouldUseProcessorPath, isVLM, dialect, draftModel, promptCache, promptCacheStats] context in
            if Task.isCancelled { throw CancellationError() }
            var hasTokenProcessingEnded = false
            var hasGenerationStarted = false

            // Persistent cross-turn KV cache bookkeeping (plain-text path only).
            // These stay nil on every other path, so the defer below is a no-op there.
            // `persistentCache` is the cache selected for THIS turn (reused-and-trimmed
            // or freshly created); `promptTokensForCache` is the full prompt token list
            // used to update the store after a successful generation.
            var persistentCache: [KVCache]? = nil
            var promptTokensForCache: [Int]? = nil
            var cacheCommitted = false

            defer {
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
                let tokens = try AgentLoop.encodeNonEmptyTokens(
                    primaryText: chatML,
                    fallbackTexts: ["hi", "a"],
                    using: tokenizer.encode(text:)
                )
                if isVLM {
                    // VLM checkpoint without processor metadata: still text-only here,
                    // but persistent caching stays disabled for this family.
                    input = try AgentLoop.makeSafeTextLMInput(tokens: tokens)
                } else if persistentCachingApplies {
                    // Plain-text LLM path — the only path that participates in
                    // cross-turn prompt caching. Diff this turn's prompt against the
                    // tokens the persisted cache physically holds, trim the cache back
                    // to the shared prefix, and feed ONLY the new suffix. This mirrors
                    // mlx_lm.server: the default prefill does not skip already-cached
                    // tokens on its own, so the caller must slice the input and trim
                    // the cache to `offset == common`.
                    promptTokensForCache = tokens

                    let cacheIsReusable = promptCache.cache.map(canTrimPromptCache) ?? false
                    // The cache's live physical length. Authoritative for the trim
                    // amount — it can be one greater than `cachedTokens.count` when a
                    // trailing stop token was fed on the previous EOS-terminated turn.
                    let liveOffset = promptCache.cache?.first?.offset ?? 0
                    let decision = AgentLoop.computePromptCacheDecision(
                        cachedTokens: promptCache.cachedTokens,
                        promptTokens: tokens,
                        cacheOffset: liveOffset,
                        cacheIsReusable: cacheIsReusable
                    )

                    if decision.reuseCache, let existing = promptCache.cache {
                        if decision.toTrim > 0 {
                            trimPromptCache(existing, numTokens: decision.toTrim)
                        }
                        // After trimming, every layer's offset must equal the shared
                        // prefix length. If any layer disagrees the cache is not a
                        // valid prefix for this prompt, so discard it and re-prefill
                        // the full prompt into a fresh cache.
                        let offsetsConsistent = existing.allSatisfy { $0.offset == decision.common }
                        if offsetsConsistent {
                            persistentCache = existing
                            let suffix = Array(tokens[decision.common...])
                            input = try AgentLoop.makeSafeTokenLMInput(tokens: suffix)
                            // Reuse indicator (flag-gated): `common` tokens are served
                            // from the previous turn's cache and skipped; only `suffix`
                            // is prefilled now. On a healthy multi-turn chat, reused
                            // should be large and new should be roughly one message.
                            if promptCacheStats {
                                frontend.emitStatus(
                                    "[PromptCache] reused \(decision.common) tok from cache, "
                                    + "prefilling \(suffix.count) new tok "
                                    + "(prompt \(tokens.count) tok, trimmed \(decision.toTrim))"
                                )
                            }
                        } else {
                            let fresh = context.model.newCache(parameters: generationParameters)
                            persistentCache = fresh
                            input = try AgentLoop.makeSafeTokenLMInput(tokens: tokens)
                            frontend.emitStatus(
                                "[PromptCache] initialized (offset mismatch after trim — "
                                + "re-prefilling \(tokens.count) tok)"
                            )
                        }
                    } else {
                        // First turn, or a divergent first token: prefill the entire
                        // prompt. Whether we KEEP the resulting cache for future reuse
                        // depends on whether this model's cache can be trimmed back to a
                        // shared prefix at all.
                        let fresh = context.model.newCache(parameters: generationParameters)
                        input = try AgentLoop.makeSafeTokenLMInput(tokens: tokens)
                        if canTrimPromptCache(fresh) {
                            persistentCache = fresh
                            frontend.emitStatus(
                                "[PromptCache] initialized (prefilling \(tokens.count) tok)"
                            )
                            if promptCacheStats {
                                frontend.emitStatus(
                                    "[PromptCache] reused 0 tok from cache, "
                                    + "prefilling \(tokens.count) new tok (prompt \(tokens.count) tok)"
                                )
                            }
                        } else {
                            // The model exposes a non-trimmable cache — e.g. a hybrid
                            // state-space/attention model (Qwen3.5's Mamba layers) or a
                            // sliding-window cache. Mamba layers keep a fixed recurrent
                            // state with no per-token entries to roll back, so cross-turn
                            // prefix reuse is impossible. Don't hold a cache we can never
                            // reuse; let the iterator build its own for this turn.
                            persistentCache = nil
                            promptTokensForCache = nil
                            if !promptCache.reuseUnavailableAnnounced {
                                promptCache.reuseUnavailableAnnounced = true
                                frontend.emitStatus(
                                    "[PromptCache] reuse unavailable for this model — "
                                    + "non-trimmable KV cache (hybrid/Mamba or sliding-window); "
                                    + "prefilling full context each turn"
                                )
                            }
                        }
                    }
                } else {
                    // Text model on a non-cacheable path (speculative decoding or
                    // TurboQuant): keep legacy behavior — prefill the full prompt.
                    input = try AgentLoop.makeSafeTokenLMInput(tokens: tokens)
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
                startsThinking: enableThinking
            )
            hasTokenProcessingEnded = true
            frontend.emit(.tokenProcessingActivity(.ended))
            hasGenerationStarted = true
            frontend.emit(.generationActivity(.started))
            var hasOpenThinkingActivity = false

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
            // Token-rate stats, captured from the terminal `.info` event and emitted
            // only after the final flush so it prints after the last streamed line.
            var generationStatMessage: String? = nil
            
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
            let tokenStream: AsyncStream<TokenGeneration> = try await withError {
                if let draftModel {
                    return try MLXLMCommon.generateTokens(
                        input: input,
                        cache: generationCache,
                        parameters: generationParameters,
                        context: context,
                        draftModel: draftModel.model,
                        numDraftTokens: currentGenerationConfig.numDraftTokens
                    )
                } else {
                    return try MLXLMCommon.generateTokens(
                        input: input,
                        cache: generationCache,
                        parameters: generationParameters,
                        context: context
                    )
                }
            }
            for await item in tokenStream {
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                switch item {
                case .token(let id):
                    generatedTokenIds.append(id)
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
                    generationStatMessage = String(format: "Generated %d tokens (%.1f tok/s), prompt: %d tokens (%.1f tok/s)",
                                                    info.generationTokenCount, info.tokensPerSecond,
                                                    info.promptTokenCount, info.promptTokensPerSecond)
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

            // Now that every streamed line (including any released by the flush
            // above) has been emitted, surface the token-rate stats. Emitting it
            // here keeps it — and the caller's "Turn complete." status — ordered
            // after the final assistant line.
            if let generationStatMessage {
                frontend.emitStatus(generationStatMessage)
            }

            // Generation completed successfully — persist the cache for the next
            // turn. The cache now physically holds prompt + generated tokens, so
            // `cachedTokens` must mirror that exact sequence for the next turn's
            // prefix diff to be correct. `cacheCommitted` disarms the defer's
            // invalidate-on-failure guard.
            if let cache = persistentCache, let promptTokens = promptTokensForCache {
                promptCache.cache = cache
                promptCache.cachedTokens = promptTokens + generatedTokenIds
                cacheCommitted = true
                // Size indicator (flag-gated): what the next turn can reuse — the
                // full prompt plus the tokens just generated.
                if promptCacheStats {
                    frontend.emitStatus(
                        "[PromptCache] committed — cache holds \(promptCache.cachedTokens.count) tok "
                        + "(prompt \(promptTokens.count) + generated \(generatedTokenIds.count))"
                    )
                }
            }

            // Strip EOS tokens if they leaked into the text
            rawResponseText = rawResponseText.replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            rawResponseText = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)

            return (text: rawResponseText, writer: writer, startedThinking: enableThinking)
        }

        return result
    }
}
