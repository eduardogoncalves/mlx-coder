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

        // Start processing spinner before inference begins
        let spinner = Spinner(message: "Processing...")
        await spinner.start()

        let result = try await modelContainer.perform { [currentGenerationConfig, renderer, chatML, imageURLs, vlmMessageData, vlmLastUserIndex, shouldUseProcessorPath, isVLM] context in
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
                    Task {
                        await spinner.updateMessage(message)
                        await spinner.start()
                    }
                }
            )
            
            var rawResponseText = ""
            var pendingChunk = ""
            var isThinking = enableThinking
            if isThinking {
                renderer.startThinking()
            }
            var hasShownVisibleOutput = false

            func stopSpinnerOnFirstVisibleOutput() {
                guard !hasShownVisibleOutput else { return }
                hasShownVisibleOutput = true
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    await spinner.stop(clearLine: true)
                    semaphore.signal()
                }
                semaphore.wait()
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
            
            for try await item in try MLXLMCommon.generateTokens(
                input: input,
                cache: tqCache,
                parameters: generationParameters,
                context: context
            ) {
                if Task.isCancelled {
                    Task { await spinner.stop(clearLine: true) }
                    throw CancellationError()
                }
                
                switch item {
                case .token(let id):
                    segmentTokens.append(id)
                    let newSegment = tokenizer.decode(tokens: segmentTokens, skipSpecialTokens: false)
                    
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
                            segment = tokenizer.decode(tokens: segmentTokens, skipSpecialTokens: false)
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
                                    renderer.printChunk(before)
                                }
                                renderer.startThinking()
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
                                    renderer.printChunk(pendingChunk)
                                    pendingChunk = ""
                                }
                            }
                        } else {
                            if let range = pendingChunk.range(of: ToolCallPattern.thinkClose) {
                                let before = String(pendingChunk[..<range.lowerBound])
                                if !before.isEmpty {
                                    stopSpinnerOnFirstVisibleOutput()
                                    renderer.printThinkingChunk(before)
                                }
                                renderer.endThinking()
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
                                    renderer.printThinkingChunk(pendingChunk)
                                    pendingChunk = ""
                                }
                            }
                        }
                    }
                case .info(let info):
                    stopSpinnerOnFirstVisibleOutput()
                    print()
                    let statMessage = String(format: "Generated %d tokens (%.1f tok/s), prompt: %d tokens (%.1f tok/s)",
                                             info.generationTokenCount, info.tokensPerSecond,
                                             info.promptTokenCount, info.promptTokensPerSecond)
                    renderer.printStatus(statMessage)
                    print()
                }
            }
            
            // Flush any remaining text in pendingChunk
            if !pendingChunk.isEmpty {
                if isThinking {
                    stopSpinnerOnFirstVisibleOutput()
                    renderer.printThinkingChunk(pendingChunk)
                } else {
                    stopSpinnerOnFirstVisibleOutput()
                    renderer.printChunk(pendingChunk)
                }
            }
            
            // Strip EOS tokens if they leaked into the text
            rawResponseText = rawResponseText.replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            rawResponseText = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            return (text: rawResponseText, writer: writer)
        }

        // Cleanup spinner if generation failed or returned nothing
        Task { await spinner.stop(clearLine: true) }

        return result
    }
}
