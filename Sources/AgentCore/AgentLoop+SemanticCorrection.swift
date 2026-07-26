// Sources/AgentCore/AgentLoop+SemanticCorrection.swift
// LLM-based semantic parameter correction for failed tool calls.

import Foundation
import MLX
import MLXLMCommon

extension AgentLoop {

    /// Structured result from semantic correction — Sendable-safe.
    struct SemanticCorrection: Sendable {
        let path: String
        let oldText: String
        let newText: String
    }

    /// Attempts to semantically correct a failed tool call using lightweight LLM inference.
    ///
    /// When `edit_file` fails because `old_text` doesn't match the file, this method:
    /// 1. Reads the actual file content
    /// 2. Sends a focused prompt to the LLM to find the correct `old_text`
    /// 3. Returns corrected arguments (preserving the original `new_text`)
    ///
    /// This avoids wasting tokens on full regeneration — the LLM only provides the
    /// corrected `old_text`, and the agent reuses the previously generated `new_text`.
    func attemptSemanticCorrection(
        toolName: String,
        arguments: [String: Any],
        errorResult: ToolResult
    ) async -> SemanticCorrection? {
        guard toolName == "edit_file" else { return nil }
        guard let path = arguments["path"] as? String else { return nil }
        guard let oldText = arguments["old_text"] as? String else { return nil }
        guard let newText = arguments["new_text"] as? String else { return nil }

        // Only attempt correction for "old_text not found" type errors
        let errorPreview = errorResult.content.prefix(100).lowercased()
        guard errorPreview.contains("not found") || errorPreview.contains("doesn't match") || errorPreview.contains("make sure") else {
            return nil
        }

        // Read the actual file content
        let resolvedPath = (path as NSString).isAbsolutePath
            ? path
            : (permissions.effectiveWorkspaceRoot as NSString).appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: resolvedPath),
              let fileContent = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            return nil
        }

        frontend.harnessIntervention("\(toolName)'s old_text didn't match the file — running a quick correction pass to locate the right text before failing the call.")

        // Build a focused, token-efficient prompt
        let maxFileChars = 8000
        let truncatedFile = fileContent.count > maxFileChars
            ? String(fileContent.prefix(maxFileChars)) + "\n... [file truncated]"
            : fileContent

        let correctionPrompt = """
        You are a precise text matching assistant. Your ONLY task is to find the exact text in the file that corresponds to the user's intended old_text.

        FILE CONTENT:
        ```
        \(truncatedFile)
        ```

        INTENDED OLD_TEXT (what the user tried to match):
        ```
        \(oldText)
        ```

        Return ONLY the exact text from the file that should be replaced. Do not explain, do not add markdown. Return the exact string as it appears in the file, preserving all whitespace and indentation.
        """

        // Generate correction with minimal tokens.
        // All penalties are disabled: the GPU penalty kernels run reductions
        // whose output size must differ from input size. On very short
        // correction sequences (or when a context size is 0) MLX asserts
        // (out.size() != in.size()) in reduce.cpp and calls abort(), which
        // cannot be caught by withError. Inheriting the main config's
        // frequencyPenalty/frequencyContextSize triggers this path.
        // Penalty quality is irrelevant for a ~512-token correction pass.
        let correctionConfig = GenerationEngine.Config(
            maxTokens: 512,
            temperature: 0.1,
            topP: 0.9,
            topK: 5,
            minP: 0.0,
            repetitionPenalty: 1.0,
            repetitionContextSize: 0,
            presencePenalty: 0.0,
            presenceContextSize: 0,
            frequencyPenalty: 0.0,
            frequencyContextSize: 0,
            kvBits: nil, // maybeQuantizeKVCache + direct cache.update() = fatalError
            kvGroupSize: currentGenerationConfig.kvGroupSize,
            quantizedKVStart: currentGenerationConfig.quantizedKVStart,
            longContextThreshold: currentGenerationConfig.longContextThreshold,
            numDraftTokens: currentGenerationConfig.numDraftTokens
        )

        guard let modelContainer else { return nil }

        do {
            let correctedOldText = try await modelContainer.perform { context in
                // Wrap MLX work in `withError` so a C++ MLX failure (e.g. a
                // reshape on an empty array, deep in the model/penalty/sampler
                // code) surfaces as a thrown Swift `MLXError` instead of the
                // library's default `fatalError`, which would kill the whole
                // process. The synchronous `TokenIterator` construction and the
                // child generation task it spawns both run inside this scope and
                // inherit the task-local handler, so any internal failure is
                // caught here and handled gracefully by the do/catch below.
                try await withError {
                    if Task.isCancelled { throw CancellationError() }
                    let tokenizer = context.tokenizer
                    let tokens = try AgentLoop.encodeNonEmptyTokens(
                        primaryText: correctionPrompt,
                        fallbackTexts: ["a"],
                        using: tokenizer.encode(text:)
                    )
                    let input = try AgentLoop.makeSafeTextLMInput(tokens: tokens)

                    var responseText = ""
                    let tokenStream = try MLXLMCommon.generateTokens(
                        input: input,
                        parameters: correctionConfig.generateParameters,
                        context: context
                    )
                    for await item in tokenStream {
                        if Task.isCancelled { throw CancellationError() }
                        if case .token(let id) = item {
                            let decoded = tokenizer.decode(tokenIds: [id], skipSpecialTokens: false)
                            responseText += decoded
                            // Early exit if we have enough text
                            if responseText.count > 2000 { break }
                        }
                    }
                    return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Clean up the response — strip markdown code blocks if present
            var cleanedOldText = correctedOldText
            if cleanedOldText.hasPrefix("```") {
                let lines = cleanedOldText.components(separatedBy: .newlines)
                cleanedOldText = lines.filter { !$0.hasPrefix("```") }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Verify the corrected text actually exists in the file
            guard fileContent.contains(cleanedOldText) else {
                frontend.harnessIntervention("the correction pass's suggested old_text still doesn't match the file — leaving the original edit_file failure in place.")
                return nil
            }

            // Verify it's different from the original attempt
            guard cleanedOldText != oldText else {
                frontend.harnessIntervention("the correction pass returned the same old_text that already failed — leaving the original edit_file failure in place.")
                return nil
            }

            frontend.harnessIntervention("corrected edit_file's old_text automatically (\(cleanedOldText.count) chars vs the model's original \(oldText.count) chars) — retrying with the fix.")

            await auditLogger?.logParameterCorrection(
                toolName: toolName,
                originalArgumentsJSON: serializedArgumentsPreview(arguments),
                correctedArgumentsJSON: serializedArgumentsPreview(["path": path, "old_text": cleanedOldText, "new_text": newText]),
                corrections: ["LLM semantic correction: old_text matched in file"]
            )

            return SemanticCorrection(path: path, oldText: cleanedOldText, newText: newText)

        } catch is CancellationError {
            return nil
        } catch {
            frontend.harnessIntervention("the automatic correction pass itself failed (\(error.localizedDescription)) — leaving the original edit_file failure in place.")
            return nil
        }
    }
}
