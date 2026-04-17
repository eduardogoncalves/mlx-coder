// Sources/AgentCore/AgentLoop+ToolCondensation.swift
// Tool result condensation — summarization and context compression for tool outputs.

import Foundation
import MLX
import MLXLMCommon

extension AgentLoop {

    func makeToolResponseForHistory(toolName: String, result: ToolResult, userGoal: String) async throws -> String {
        let rawToolResponse = ToolResultCondensationPolicy.joinedToolOutput(result: result)

        guard ToolResultCondensationPolicy.shouldCondense(toolName: toolName, result: result, config: condensationConfig) else {
            return applyFactOnlyPreambleIfNeeded(toolName: toolName, toolResponse: rawToolResponse)
        }

        let beforeTokens = ToolResultCondensationPolicy.estimatedTokenCount(
            for: rawToolResponse,
            charsPerToken: condensationConfig.charsPerTokenEstimate
        )

        // Some checkpoints are unstable when invoked for secondary summarization
        // passes after file-read tools. Use bounded raw fallback directly.
        let nonLLMCondensationTools: Set<String> = ["read_file", "read_many"]
        if nonLLMCondensationTools.contains(toolName) {
            let fallback = ToolResultCondensationPolicy.boundedFallbackRawMessage(
                toolName: toolName,
                raw: rawToolResponse,
                maxChars: condensationConfig.fallbackRawChars
            )
            let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                for: fallback,
                charsPerToken: condensationConfig.charsPerTokenEstimate
            )
            await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: true))
            if renderer.verbose {
                renderer.printStatus("[debug] Tool result condensation used non-LLM fallback for \(toolName): before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
            }
            return fallback
        }

        do {
            let rawSummary = try await summarizeToolOutputEphemeral(
                toolName: toolName,
                userGoal: userGoal,
                rawToolResponse: rawToolResponse
            )

            let summary = ToolResultCondensationPolicy.sanitizeSummary(
                rawSummary,
                maxChars: condensationConfig.maxSummaryChars
            )

            if renderer.verbose, !summary.isEmpty {
                renderer.printStatus("[debug] Condensed summary for \(toolName):")
                print(summary)
            }

            guard !summary.isEmpty else {
                let fallback = ToolResultCondensationPolicy.boundedFallbackRawMessage(
                    toolName: toolName,
                    raw: rawToolResponse,
                    maxChars: condensationConfig.fallbackRawChars
                )
                let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                    for: fallback,
                    charsPerToken: condensationConfig.charsPerTokenEstimate
                )
                await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: true))
                if renderer.verbose {
                    renderer.printStatus("[debug] Tool result condensation fallback for \(toolName): before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
                }
                return fallback
            }

            let condensed = ToolResultCondensationPolicy.formatCondensedToolMessage(toolName: toolName, summary: summary)
            let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                for: condensed,
                charsPerToken: condensationConfig.charsPerTokenEstimate
            )
            await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: false))
            if renderer.verbose {
                renderer.printStatus("[debug] Tool result condensed for \(toolName): before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
            }
            return condensed
        } catch {
            let fallback = ToolResultCondensationPolicy.boundedFallbackRawMessage(
                toolName: toolName,
                raw: rawToolResponse,
                maxChars: condensationConfig.fallbackRawChars
            )
            let afterTokens = ToolResultCondensationPolicy.estimatedTokenCount(
                for: fallback,
                charsPerToken: condensationConfig.charsPerTokenEstimate
            )
            await hooks.emit(.compression(toolName: toolName, beforeTokens: beforeTokens, afterTokens: afterTokens, usedFallback: true))
            if renderer.verbose {
                renderer.printStatus("[debug] Tool result condensation failed for \(toolName): \(error.localizedDescription). before≈\(beforeTokens) tokens, after≈\(afterTokens), saved≈\(max(0, beforeTokens - afterTokens))")
            }
            return fallback
        }
    }

    func summarizeToolOutputEphemeral(toolName: String, userGoal: String, rawToolResponse: String) async throws -> String {
        let effectiveGoal = userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let extractionGoal = effectiveGoal.isEmpty
            ? "No explicit user goal is available. Extract only the most relevant facts for likely task completion."
            : effectiveGoal

        let systemPrompt = "You are a precise extraction engine. Return only facts relevant to the current goal."
        let userPrompt = """
        Goal:
        \(extractionGoal)

        Tool:
        \(toolName)

        Instructions:
        - Extract only information relevant to the goal.
        - Keep exact numbers, names, dates, versions, and quoted phrases unchanged.
        - Do not add outside knowledge.
        - If information is missing or ambiguous, explicitly say so.
        - Keep the response under \(condensationConfig.summaryTargetTokens) tokens.

        Raw tool output:
        \(rawToolResponse)
        """

        let extractionConfig = GenerationEngine.Config(
            maxTokens: condensationConfig.summaryTargetTokens,
            temperature: 0.1,
            topP: currentGenerationConfig.topP,
            topK: currentGenerationConfig.topK,
            minP: currentGenerationConfig.minP,
            repetitionPenalty: currentGenerationConfig.repetitionPenalty,
            repetitionContextSize: currentGenerationConfig.repetitionContextSize,
            presencePenalty: 0,
            presenceContextSize: currentGenerationConfig.presenceContextSize,
            frequencyPenalty: 0,
            frequencyContextSize: currentGenerationConfig.frequencyContextSize,
            kvBits: currentGenerationConfig.kvBits,
            kvGroupSize: currentGenerationConfig.kvGroupSize,
            quantizedKVStart: currentGenerationConfig.quantizedKVStart
        )

        let chatML = """
        \(ToolCallPattern.imStart)system
        \(systemPrompt)
        \(ToolCallPattern.imEnd)
        \(ToolCallPattern.imStart)user
        \(userPrompt)
        \(ToolCallPattern.imEnd)
        \(ToolCallPattern.imStart)assistant
        """

        let modelContainer = try requireLoadedModelContainer()
        // Some VLM checkpoints require processor-driven prompt formatting even on
        // text-only turns (e.g. summarization). Guard with processor-config presence
        // so local checkpoints missing processor metadata still use direct tokenization.
        let isVLM = await modelContainer.isVLM
        let shouldUseProcessorPath = isVLM && modelHasProcessorConfig(modelPath)
        let extracted = try await modelContainer.perform { [shouldUseProcessorPath] context in
            if Task.isCancelled { throw CancellationError() }

            let input: LMInput
            if shouldUseProcessorPath {
                let userInput = UserInput(chat: [.system(systemPrompt), .user(userPrompt)])
                let prepared = try await context.processor.prepare(input: userInput)
                if prepared.text.tokens.size > 0 {
                    input = prepared
                } else {
                    let tokens = try AgentLoop.encodeNonEmptyTokens(
                        primaryText: chatML,
                        fallbackTexts: [userPrompt, "hi", "a"],
                        using: context.tokenizer.encode(text:)
                    )
                    let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
                    let mask = ones(like: tokenArray).asType(.int8)
                    input = LMInput(text: .init(tokens: tokenArray, mask: mask), image: nil)
                }
            } else {
                let tokens = try AgentLoop.encodeNonEmptyTokens(
                    primaryText: chatML,
                    fallbackTexts: [userPrompt, "hi", "a"],
                    using: context.tokenizer.encode(text:)
                )
                let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
                let mask = ones(like: tokenArray).asType(.int8)
                input = LMInput(text: .init(tokens: tokenArray, mask: mask), image: nil)
            }
            var responseText = ""

            for try await item in try MLXLMCommon.generateTokens(
                input: input,
                parameters: extractionConfig.generateParameters,
                context: context
            ) {
                if Task.isCancelled { throw CancellationError() }
                switch item {
                case .token(let tokenId):
                    responseText += context.tokenizer.decode(tokens: [tokenId], skipSpecialTokens: false)
                case .info:
                    break
                }
            }

            return responseText
        }

        return ToolCallParser.stripThinking(extracted)
            .replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            .replacingOccurrences(of: ToolCallPattern.imEnd, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applyFactOnlyPreambleIfNeeded(toolName: String, toolResponse: String) -> String {
        let webToolNames: Set<String> = ["web_search", "web_fetch"]
        guard webToolNames.contains(toolName) else {
            return toolResponse
        }

        let factOnlyPreamble = """
            [INSTRUCTION]
            Act as a Fact-Only Extractor:
            - Exact values only. Never round, convert, or rephrase numbers/names/versions.
            - No conclusions, summaries, or trends unless the source states them explicitly.
            - Do not fill gaps with prior knowledge.
            - If the page is inaccessible or ambiguous, say so before answering.
            - Use the source's exact terminology.
            [INSTRUCTION]

            """
        return factOnlyPreamble + toolResponse
    }
}
