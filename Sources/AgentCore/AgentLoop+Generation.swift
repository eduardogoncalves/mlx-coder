// Sources/AgentCore/AgentLoop+Generation.swift
// Response generation — tokenization, streaming, and think-block rendering.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

extension AgentLoop {

    /// Generate a response from the model using the current conversation history.
    /// Returns the response text and the streaming writer (for streamed tool calls).
    func generateResponse() async throws -> (text: String, writer: StreamingToolCallWriter) {
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

        // Notify the front-end that generation is starting. Adapters render
        // their own spinner / progress indicator on this event.
        frontend.emit(.generationActivity(.started(message: "Processing...")))

        let result = try await modelContainer.perform { [currentGenerationConfig, frontend, chatML, imageURLs, vlmMessageData, vlmLastUserIndex, shouldUseProcessorPath, isVLM] context in
            if Task.isCancelled { throw CancellationError() }

            // Processor path: for image turns and model families that require processor-driven
            // prompt preparation, use UserInput +
            // processor.prepare so model-specific prompt formatting and tensor shapes are respected.
            // Fallback text-only path tokenizes ChatML directly.
            let tokenizer = context.tokenizer
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
                    input = try AgentLoop.makeSafeTextLMInput(tokens: tokens)
                } else {
                    input = try AgentLoop.makeSafeTokenLMInput(tokens: tokens)
                }
            }

            // Clean up stale .tmp files from previous crashed/interrupted sessions.
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mlx-coder-streaming")
            try? FileManager.default.removeItem(at: tmpDir)
            // Streaming writer: streams tool call content to .tmp files during generation
            let writer = StreamingToolCallWriter(
                toolCallOpen: ToolCallPattern.toolCallOpen,
                toolCallClose: ToolCallPattern.toolCallClose,
                onStatusChange: { message in
                    frontend.emit(.generationActivity(.phase(message)))
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
            if enableThinking {
                // Emit thinkingStarted immediately: the model is already inside the
                // think block from token 1 (the open tag is in the prompt, not output).
                frontend.emit(.thinkingStarted)
            }
            var hasShownVisibleOutput = false

            func stopSpinnerOnFirstVisibleOutput() {
                guard !hasShownVisibleOutput else { return }
                hasShownVisibleOutput = true
                frontend.emit(.generationActivity(.ended))
            }

            var generationParameters = currentGenerationConfig.generateParameters
            if shouldUseProcessorPath {
                generationParameters.repetitionPenalty = nil
                generationParameters.presencePenalty = nil
                generationParameters.frequencyPenalty = nil
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
            
            // For correct streaming detokenization
            var segmentTokens = [Int]()
            var segment = ""
            
            let tokenStream = try MLXLMCommon.generateTokens(
                input: input,
                cache: tqCache,
                parameters: generationParameters,
                context: context
            )
            for await item in tokenStream {
                if Task.isCancelled {
                    frontend.emit(.generationActivity(.ended))
                    throw CancellationError()
                }
                
                switch item {
                case .token(let id):
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
                        case .thinkingStarted:
                            frontend.emit(.thinkingStarted)
                        case .thinkingChunk(let chunk):
                            // Don't stop the spinner during thinking: the spinner
                            // should keep animating with "Thinking…" label while
                            // reasoning tokens stream in. Stopping it here (before
                            // the TUI consumer processes the chunk) would tear down
                            // the footer rendering state before any think line is
                            // visible, causing all chunks to appear batched at the end.
                            frontend.emit(.thinkingChunk(chunk))
                        case .thinkingEnded:
                            frontend.emit(.thinkingEnded)
                        case .assistantTextChunk(let chunk):
                            // Stop the "Processing…" spinner on the first visible
                            // response token (after thinking, if any).
                            stopSpinnerOnFirstVisibleOutput()
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
                    stopSpinnerOnFirstVisibleOutput()
                    let statMessage = String(format: "Generated %d tokens (%.1f tok/s), prompt: %d tokens (%.1f tok/s)",
                                             info.generationTokenCount, info.tokensPerSecond,
                                             info.promptTokenCount, info.promptTokensPerSecond)
                    frontend.emitStatus(statMessage)
                }
            }
            
            // Flush any remaining buffered state in the parser
            for event in parser.flush() {
                switch event {
                case .thinkingChunk(let chunk):
                    stopSpinnerOnFirstVisibleOutput()
                    frontend.emit(.thinkingChunk(chunk))
                case .assistantTextChunk(let chunk):
                    stopSpinnerOnFirstVisibleOutput()
                    let result = writer.process(chunk)
                    if !result.displayText.isEmpty {
                        frontend.emit(.assistantTextChunk(result.displayText))
                    }
                default:
                    break
                }
            }
            
            // Strip EOS tokens if they leaked into the text
            rawResponseText = rawResponseText.replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            rawResponseText = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            return (text: rawResponseText, writer: writer)
        }

        // Cleanup activity indicator on exit (no-op if already ended).
        frontend.emit(.generationActivity(.ended))

        return result
    }
}
