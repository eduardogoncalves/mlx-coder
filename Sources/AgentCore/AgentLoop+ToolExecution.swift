// Sources/AgentCore/AgentLoop+ToolExecution.swift
// Tool registration, execution helpers, and streamed tool call handling.

import Foundation

extension AgentLoop {

    func registerToolsInternal() async {
        guard let modelContainer else { return }

        // Filesystem tools
        await registry.register(ReadFileTool(permissions: permissions))
        await registry.register(WriteFileTool(permissions: permissions))
        await registry.register(AppendFileTool(permissions: permissions))
        await registry.register(EditFileTool(permissions: permissions))
        await registry.register(PatchTool(permissions: permissions))
        await registry.register(ListDirTool(permissions: permissions))
        await registry.register(ReadManyTool(permissions: permissions))

        // Search tools
        await registry.register(GlobTool(permissions: permissions))
        await registry.register(GrepTool(permissions: permissions))
        await registry.register(CodeSearchTool(permissions: permissions))

        // Shell
        await registry.register(BashTool(permissions: permissions, useSandbox: useSandbox))

        // Agent tools
        await registry.register(TaskTool(
            modelContainer: modelContainer,
            permissions: permissions,
            generationConfig: currentGenerationConfig,
            modelPath: modelPath,
            useSandbox: useSandbox,
            parentRegistry: registry,
            renderer: renderer
        ))
        await registry.register(TodoTool(workspaceRoot: permissions.workspaceRoot))
        await registry.register(ProjectExpertLoRATool(modelContainer: modelContainer, workspaceRoot: permissions.workspaceRoot, modelPath: modelPath))

        // Web tools
        await registry.register(WebFetchTool(
            modelContainer: modelContainer,
            generationConfig: currentGenerationConfig
        ))
        await registry.register(WebSearchTool())

        // LSP tools (.NET/C#)
        await registry.register(LSPDiagnosticsTool(permissions: permissions))
        await registry.register(LSPHoverTool(permissions: permissions))
        await registry.register(LSPReferencesTool(permissions: permissions))
        await registry.register(LSPDefinitionTool(permissions: permissions))
        await registry.register(LSPCompletionTool(permissions: permissions))
        await registry.register(LSPSignatureHelpTool(permissions: permissions))
        await registry.register(LSPDocumentSymbolsTool(permissions: permissions))
        await registry.register(LSPRenameTool(permissions: permissions))
    }

    func extractPolicyTargetPath(from arguments: [String: Any]) -> String? {
        let directKeys = ["path", "file_path", "filePath", "search_path", "directory", "dir", "workspace"]
        for key in directKeys {
            if let value = arguments[key] as? String, !value.isEmpty {
                return value
            }
        }

        if let paths = arguments["paths"] as? [String], let first = paths.first, !first.isEmpty {
            return first
        }

        return nil
    }

    func isDestructiveToolCall(_ call: ToolCallParser.ParsedToolCall) -> Bool {
        let alwaysDestructiveTools: Set<String> = ["write_file", "edit_file", "append_file", "patch", "bash", "task"]
        if alwaysDestructiveTools.contains(call.name) {
            return true
        }

        if call.name == "lsp_rename" {
            if let apply = call.arguments["apply"] as? Bool {
                return apply
            }
            if let applyNumber = call.arguments["apply"] as? NSNumber {
                return applyNumber.boolValue
            }
        }

        return false
    }

    func serializedArgumentsPreview(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: arguments)
        }
        return text
    }

    // MARK: - Streamed Tool Call Handling

    /// Handles a tool call whose content was streamed to a .tmp file during generation.
    /// Shows a diff to the user and applies the change if approved.
    func handleStreamedToolCall(_ call: StreamedToolCall) async -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(call.path)
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error(error.localizedDescription)
        }

        // Read the tmp content
        guard let tmpContent = try? String(contentsOf: call.contentFile, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error("Failed to read streamed content for \(call.path)")
        }

        // Read the original file content (if exists)
        let originalContent: String?
        if FileManager.default.fileExists(atPath: resolvedPath) {
            originalContent = try? String(contentsOfFile: resolvedPath, encoding: .utf8)
        } else {
            originalContent = nil
        }

        // Generate and display the diff from the tool's proposed final file content.
        let previewContent: String
        switch call.toolName {
        case "edit_file":
            if let originalContent,
               let oldText = (
                (call.otherArgs["old_text"] as? String)
                ?? (call.otherArgs["oldText"] as? String)
                ?? (call.otherArgs["old"] as? String)
                ?? (call.otherArgs["search_text"] as? String)
                ?? (call.otherArgs["searchText"] as? String)
               ),
               !oldText.isEmpty,
               let range = originalContent.range(of: oldText) {
                previewContent = originalContent.replacingCharacters(in: range, with: tmpContent)
            } else {
                // Fallback for malformed/partial arguments; execution-time correction
                // still handles these cases before writing.
                previewContent = tmpContent
            }
        case "append_file":
            previewContent = (originalContent ?? "") + tmpContent
        default:
            previewContent = tmpContent
        }

        let diff = DiffGenerator.generate(original: originalContent, new: previewContent, path: call.path)
        renderer.printStatus("\n\(diff)")

        // Ask for approval
        let approval: (approved: Bool, suggestion: String?)
        if permissions.approvalMode == .yolo {
            approval = (true, nil)
        } else if permissions.approvalMode == .autoEdit && !["write_file", "edit_file", "append_file"].contains(call.toolName) {
            // autoEdit only auto-approves edit tools
            var approvalArguments = call.otherArgs
            approvalArguments["path"] = call.path
            approval = await askForToolApproval(name: call.toolName, arguments: approvalArguments, isPlanMode: mode == .plan)
        } else if autoApproveAllTools {
            approval = (true, nil)
        } else {
            var approvalArguments = call.otherArgs
            approvalArguments["path"] = call.path
            approval = await askForToolApproval(name: call.toolName, arguments: approvalArguments, isPlanMode: mode == .plan)
        }

        if !approval.approved {
            try? FileManager.default.removeItem(at: call.contentFile)
            if let suggestion = approval.suggestion {
                return .error("User rejected the file change for \(call.path) with this feedback/suggestion: \(suggestion)")
            }
            return .error("User rejected the file change for \(call.path)")
        }

        // Apply the change
        do {
            switch call.toolName {
            case "write_file":
                // Replace existing file content if present; otherwise move into place.
                let targetURL = URL(fileURLWithPath: resolvedPath)
                let parentDir = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: call.contentFile)
                } else {
                    try FileManager.default.moveItem(at: call.contentFile, to: targetURL)
                }
                return .success("Wrote \(call.path) (\(tmpContent.count) bytes)")

            case "edit_file":
                // For edit_file, the tmp contains new_text; we need old_text from otherArgs
                guard let fileContent = originalContent else {
                    // Path not found — preserve new_text so the LLM only needs to fix the path.
                    preservedEditTmpFiles[call.path] = call.contentFile
                    return .error("File not found: \(call.path). new_text is preserved and will be reused automatically; only correct the path.")
                }

                // Streamed calls bypass normal execution-time correction, so run the same
                // deterministic correction pipeline here for aliases and fuzzy old_text fixes.
                var streamedArguments = call.otherArgs
                streamedArguments["path"] = call.path
                streamedArguments["new_text"] = tmpContent
                let correctionResult = await ParameterCorrectionService.correct(
                    toolName: "edit_file",
                    arguments: streamedArguments,
                    workspaceRoot: permissions.effectiveWorkspaceRoot
                )
                if correctionResult.wasCorrected {
                    for correction in correctionResult.corrections {
                        renderer.printStatus("[auto-correct] edit_file (streamed): \(correction)")
                    }
                }

                guard let oldText = correctionResult.correctedArguments["old_text"] as? String,
                      !oldText.isEmpty else {
                    try? FileManager.default.removeItem(at: call.contentFile)
                    return .error("Missing old_text for edit_file")
                }
                let occurrences = fileContent.components(separatedBy: oldText).count - 1
                if occurrences != 1 {
                    if occurrences == 0 {
                        // Try semantic correction before giving up, passing tmpContent as new_text.
                        let fakeArgs: [String: Any] = ["path": call.path, "old_text": oldText, "new_text": tmpContent]
                        let fakeError = ToolResult.error("old_text not found in \(call.path). Make sure the text matches exactly.")
                        if let correction = await attemptSemanticCorrection(toolName: "edit_file", arguments: fakeArgs, errorResult: fakeError) {
                            renderer.printStatus("[auto-correct] Retrying streamed edit_file with corrected old_text...")
                            let corrected = fileContent.replacingOccurrences(of: correction.oldText, with: tmpContent)
                            do {
                                try corrected.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                                try? FileManager.default.removeItem(at: call.contentFile)
                                return .success("Applied edit to \(call.path) (old_text auto-corrected)")
                            } catch {
                                // Write failed even after correction — preserve tmp.
                                preservedEditTmpFiles[call.path] = call.contentFile
                                return .error("Failed to write \(call.path) after auto-correction: \(error.localizedDescription). new_text is preserved and will be reused automatically.")
                            }
                        }
                        // Semantic correction unavailable or unsuccessful — preserve tmp.
                        preservedEditTmpFiles[call.path] = call.contentFile
                        return .error("old_text not found in \(call.path). Make sure the text matches exactly, including whitespace. new_text is preserved and will be reused automatically; only correct old_text.")
                    } else {
                        // Duplicate match — preserve tmp and ask for more context.
                        preservedEditTmpFiles[call.path] = call.contentFile
                        return .error("old_text found \(occurrences) times in \(call.path). Must be unique — add more surrounding context to old_text. new_text is preserved and will be reused automatically.")
                    }
                }
                let updatedContent = fileContent.replacingOccurrences(of: oldText, with: tmpContent)
                do {
                    try updatedContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                } catch {
                    // Write failed — preserve tmp for retry.
                    preservedEditTmpFiles[call.path] = call.contentFile
                    return .error("Failed to write \(call.path): \(error.localizedDescription). new_text is preserved and will be reused automatically; only correct the path or permissions.")
                }
                try? FileManager.default.removeItem(at: call.contentFile)
                return .success("Applied edit to \(call.path)")

            case "append_file":
                // Append tmp content to original file
                if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: resolvedPath)) {
                    try fh.seekToEnd()
                    try fh.write(contentsOf: tmpContent.data(using: .utf8) ?? Data())
                    fh.closeFile()
                } else {
                    try tmpContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                }
                try? FileManager.default.removeItem(at: call.contentFile)
                return .success("Appended to \(call.path) (\(tmpContent.count) bytes)")

            default:
                try? FileManager.default.removeItem(at: call.contentFile)
                return .error("Unsupported streamed tool: \(call.toolName)")
            }
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error("Failed to apply change to \(call.path): \(error.localizedDescription)")
        }
    }
}
