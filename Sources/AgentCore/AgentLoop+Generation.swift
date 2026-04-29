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
            var pendingChunk = ""
            var isThinking = enableThinking
            if isThinking {
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
                    
                    // Normalize streamed text (including tool-call content handling)
                    // before adding to response/output buffers.
                    let streamResult = writer.process(newText)
                    let displayText = streamResult.displayText
                    
                    if newText.hasSuffix("\n") {
                        if let lastToken = segmentTokens.last {
                            segmentTokens = [lastToken]
                            segment = tokenizer.decode(tokenIds: segmentTokens, skipSpecialTokens: false)
                        }
                    } else {
                        segment = newSegment
                    }
                    
                    pendingChunk += displayText
                    
                    while !pendingChunk.isEmpty {
                        if !isThinking {
                            if let range = pendingChunk.range(of: ToolCallPattern.thinkOpen) {
                                let before = String(pendingChunk[..<range.lowerBound])
                                if !before.isEmpty {
                                    stopSpinnerOnFirstVisibleOutput()
                                    frontend.emit(.assistantTextChunk(before))
                                }
                                frontend.emit(.thinkingStarted)
                                isThinking = true
                                pendingChunk = String(pendingChunk[range.upperBound...])
                                if pendingChunk.hasPrefix("\n") { pendingChunk.removeFirst() }
                            } else {
                                // Hold if it might be the start of `<think>`
                                let prefixes = ["<", "<t", "<th", "<thi", "<thin", "<think"]
                                if prefixes.contains(where: pendingChunk.hasSuffix) {
                                    break
                                } else {
                                    stopSpinnerOnFirstVisibleOutput()
                                    frontend.emit(.assistantTextChunk(pendingChunk))
                                    pendingChunk = ""
                                }
                            }
                        } else {
                            if let range = pendingChunk.range(of: ToolCallPattern.thinkClose) {
                                let before = String(pendingChunk[..<range.lowerBound])
                                if !before.isEmpty {
                                    stopSpinnerOnFirstVisibleOutput()
                                    frontend.emit(.thinkingChunk(before))
                                }
                                frontend.emit(.thinkingEnded)
                                isThinking = false
                                pendingChunk = String(pendingChunk[range.upperBound...])
                                if pendingChunk.hasPrefix("\n") { pendingChunk.removeFirst() }
                            } else {
                                // Hold if it might be the start of `</think>`
                                let prefixes = ["<", "</", "</t", "</th", "</thi", "</thin", "</think"]
                                if prefixes.contains(where: pendingChunk.hasSuffix) {
                                    break
                                } else {
                                    stopSpinnerOnFirstVisibleOutput()
                                    frontend.emit(.thinkingChunk(pendingChunk))
                                    pendingChunk = ""
                                }
                            }
                        }
                    }
                case .info(let info):
                    stopSpinnerOnFirstVisibleOutput()
                    let statMessage = String(format: "Generated %d tokens (%.1f tok/s), prompt: %d tokens (%.1f tok/s)",
                                             info.generationTokenCount, info.tokensPerSecond,
                                             info.promptTokenCount, info.promptTokensPerSecond)
                    frontend.emitStatus(statMessage)
                }
            }
            
            // Flush any remaining text in pendingChunk
            if !pendingChunk.isEmpty {
                if isThinking {
                    stopSpinnerOnFirstVisibleOutput()
                    frontend.emit(.thinkingChunk(pendingChunk))
                } else {
                    stopSpinnerOnFirstVisibleOutput()
                    frontend.emit(.assistantTextChunk(pendingChunk))
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
