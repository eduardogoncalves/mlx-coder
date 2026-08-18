// Sources/AgentCore/AgentLoop+ToolExecution.swift
// Tool registration, execution helpers, and streamed tool call handling.

import Foundation

extension AgentLoop {

    func registerToolsInternal() async {
        // Tools that do NOT depend on a loaded local model container — these
        // register on every backend, including online ones (OpenRouter etc.).

        // Filesystem tools
        await registry.register(ReadFileTool(permissions: permissions))
        await registry.register(PlanFileTool(permissions: permissions))
        await registry.register(WriteFileTool(permissions: permissions))
        await registry.register(AppendFileTool(permissions: permissions))
        await registry.register(EditFileTool(permissions: permissions))
        await registry.register(PatchTool(permissions: permissions))
        await registry.register(ListDirTool(permissions: permissions))
        await registry.register(ReadManyTool(permissions: permissions))

        // Search tools
        await registry.register(GlobTool(permissions: permissions))
        await registry.register(GrepTool(permissions: permissions))
        await registry.register(CodeSearchTool(permissions: permissions, codeGraphIndexer: codeGraphIndexer))

        // Shell
        await registry.register(BashTool(permissions: permissions, useSandbox: useSandbox))

        // Agent tools that don't need a model container. Namespaced by this
        // AgentLoop's stable per-instance sessionId so a fresh top-level run
        // (fresh process, fresh sessionId) never inherits todo items left
        // over by a previous, unrelated run — it still persists across turns
        // within this one run, since sessionId is stable for the loop's
        // lifetime. See TodoTool's `sessionNamespace` docs.
        await registry.register(TodoTool(workspaceRoot: permissions.workspaceRoot, sessionNamespace: sessionId))

        // Skills
        await registry.register(ReadSkillTool(skills: SkillsRegistry(workspaceRoot: permissions.workspaceRoot)))

        // Lets the orchestrator pause the turn to ask the human a structured
        // multiple-choice clarifying question instead of guessing or asking
        // in free-form prose. Only available to the top-level orchestrator —
        // sub-agents talk to the orchestrator, not the human, so they never
        // get this tool registered in their own scoped registry (TaskTool.swift).
        await registry.register(AskUserQuestionTool(frontend: frontend))

        // Web tools that don't need a model container
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

        // Memory tools
        await registry.register(LogKnowledgeTool(workspaceRoot: permissions.workspaceRoot))
        await registry.register(SearchKnowledgeTool(workspaceRoot: permissions.workspaceRoot))

        // Lets the orchestrator recover a truncated sub-agent digest by reading
        // its archived run log directly, instead of spawning another sub-agent
        // just to read a file. Read-only and sandbox-scoped.
        await registry.register(TaskOutputTool(permissions: permissions))

        // `task` works with or without a loaded local container — remote-backend
        // orchestrators can still delegate to remote-backed roles. Only
        // container-bound tools (LoRA expert routing, local web summarization)
        // are skipped when no local model is loaded.
        await registry.register(TaskTool(
            modelContainer: modelContainer,
            permissions: permissions,
            generationConfig: currentGenerationConfig,
            modelPath: modelPath,
            useSandbox: useSandbox,
            parentRegistry: registry,
            frontend: frontend,
            roleModels: AgentRoleRegistry.current(workspaceRoot: permissions.workspaceRoot).roleModelMap,
            parentAgentLoop: self,
            toolOutputSpool: toolOutputSpoolConfig,
            codeGraphIndexer: codeGraphIndexer
        ))
        if let modelContainer {
            await registry.register(ProjectExpertLoRATool(modelContainer: modelContainer, workspaceRoot: permissions.workspaceRoot, modelPath: modelPath, frontend: frontend))
            await registry.register(WebFetchTool(
                modelContainer: modelContainer,
                generationConfig: currentGenerationConfig
            ))
        }
    }

    func extractPolicyTargetPath(from arguments: [String: Any]) -> String? {
        let directKeys = ["path", "file_path", "filePath", "search_path", "directory", "dir", "workspace"]
        for key in directKeys {
            if let value = arguments[key] as? String, !value.isEmpty {
                return permissions.resolveAbsolutePath(value)
            }
        }

        if let paths = arguments["paths"] as? [String], let first = paths.first, !first.isEmpty {
            return permissions.resolveAbsolutePath(first)
        }

        return nil
    }

    func isDestructiveToolCall(_ call: ToolCallParser.ParsedToolCall) -> Bool {
        let alwaysDestructiveTools: Set<String> = ["write_file", "edit_file", "append_file", "patch", "bash"]
        if alwaysDestructiveTools.contains(call.name) {
            return true
        }

        // plan_file's 'read' action is non-mutating (like read_file) and
        // should not require the same approval as 'write'/'edit'.
        if call.name == "plan_file" {
            return (call.arguments["action"] as? String) != "read"
        }

        // A `task(...)` call is only as destructive as what it delegates to:
        // the orchestrator must be free to call read-only profiles (planner,
        // reviewer, codebase_research, ...) without approval — even in PLAN
        // mode, since that's the only way it can research anything — but
        // delegating to a profile that can write files or run shell commands
        // still needs the same approval a direct write_file/bash call would.
        if call.name == "task" {
            return TaskTool.isMutatingTaskCall(arguments: call.arguments)
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

    func isFileModificationToolName(_ call: ToolCallParser.ParsedToolCall) -> Bool {
        if call.name == "plan_file" {
            return (call.arguments["action"] as? String) != "read"
        }
        return ["write_file", "edit_file", "append_file", "patch"].contains(call.name)
    }

    func isReadOnlyBashCall(_ call: ToolCallParser.ParsedToolCall) -> Bool {
        guard call.name == "bash" else { return false }
        guard let command = call.arguments["command"] as? String else { return false }
        return Self.isReadOnlyBashCommand(command)
    }

    static func isReadOnlyBashCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()

        // Conservative safety gate: reject shell chaining, substitution and redirection.
        let blockedPunctuation = ["&&", "||", ";", "|", ">", "<", "$(", "`"]
        if blockedPunctuation.contains(where: { lowered.contains($0) }) {
            return false
        }

        // Reject command flags that mutate the filesystem even on otherwise
        // read-only commands. Each token below either deletes (`-delete`),
        // spawns another mutating command (`-exec`, `-execdir`, `-ok`,
        // `-okdir`), or writes its results into an attacker-controlled file
        // outside of any redirection check (`-fprint`, `-fprintf`, `-fls`
        // take a destination filename argument). Tokens are checked whole
        // word to avoid blocking innocent substrings (e.g. a file path
        // called "delete-old"); we additionally strip surrounding shell
        // quotes from each token so that `find . '-delete'` and
        // `find . "-delete"` are also caught — without this, the naive
        // whitespace-split would treat the quoted argument as a distinct
        // token (`'-delete'`) and miss the match.
        let mutatingTokens: Set<String> = [
            "-delete",
            "-exec",
            "-execdir",
            "-fprint",
            "-fprintf",
            "-fls",
            "-ok",
            "-okdir",
        ]
        let quoteChars: Set<Character> = ["'", "\""]
        let tokens: [String] = lowered
            .split(whereSeparator: { $0.isWhitespace })
            .map { rawToken in
                // Only strip matching leading/trailing quotes so legitimate
                // paths containing a single embedded quote (e.g.
                // `some'file.txt`) are not silently normalised.
                let s = String(rawToken)
                guard let first = s.first, let last = s.last,
                      s.count >= 2, first == last, quoteChars.contains(first) else {
                    return s
                }
                return String(s.dropFirst().dropLast())
            }
        if tokens.contains(where: { mutatingTokens.contains($0) }) {
            return false
        }

        let mutatingPrefixes = [
            "rm ", "mv ", "cp ", "touch ", "mkdir ", "rmdir ", "chmod ", "chown ",
            "ln ", "sed -i", "perl -i", "tee ", "dd ", "truncate ",
            "git add", "git commit", "git push", "git pull", "git merge", "git rebase",
            "git checkout", "git switch", "git restore", "git reset", "git clean",
            "git stash", "git apply", "git cherry-pick", "git revert", "git fetch",
            "npm install", "npm ci", "pnpm install", "yarn install", "pip install",
            "go mod tidy", "cargo add", "swift package update"
        ]
        if mutatingPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return false
        }

        let readOnlyPrefixes = [
            "pwd", "ls", "find ", "cat ", "head ", "tail ", "wc ", "du ", "df",
            "grep ", "rg ", "which ", "whereis ", "type ", "echo ", "printf ",
            "env", "printenv", "uname", "sw_vers", "ps ",
            "git status", "git log", "git show", "git diff", "git branch",
            "git remote", "git rev-parse", "git describe", "git reflog"
        ]
        return readOnlyPrefixes.contains(where: { lowered.hasPrefix($0) })
    }

    func serializedArgumentsPreview(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: arguments)
        }
        return text
    }

    // MARK: - Truncated Streamed Tool Call Recovery

    /// Result of committing a partially-streamed write to disk: the user-visible
    /// `ToolResult` plus the tail of the saved content so the agent can hint the
    /// model about where to resume from.
    struct TruncatedWriteCommit {
        let result: ToolResult
        let tail: String
    }

    /// Commits a partially-streamed write to its target path so the bytes already
    /// produced by the model are not wasted. Only `write_file` and `append_file`
    /// are recoverable this way: their semantics tolerate an incremental commit
    /// + later append. Other tools (e.g. `edit_file`) need their full payload
    /// before they can be applied and are not handled here.
    func commitTruncatedStreamedWrite(_ call: TruncatedStreamedToolCall) async -> TruncatedWriteCommit {
        // Same hard guard as executeToolCall/handleStreamedToolCall: the
        // orchestrator only ever has task/todo/plan_file.
        if role == nil, !AgentLoop.orchestratorAllowedToolNames.contains(call.toolName) {
            try? FileManager.default.removeItem(at: call.contentFile)
            return TruncatedWriteCommit(
                result: .error("'\(call.toolName)' is not available to you directly — you are the orchestrator and only have task/todo/plan_file. Delegate this work instead, e.g. task(profile: \"executor\", description: \"...\") to write/edit files."),
                tail: ""
            )
        }

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(call.path)
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return TruncatedWriteCommit(result: .error(error.localizedDescription), tail: "")
        }

        guard let tmpContent = try? String(contentsOf: call.contentFile, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: call.contentFile)
            return TruncatedWriteCommit(result: .error("Failed to read truncated streamed content for \(call.path)"), tail: "")
        }

        // Hard write-guard: this is the third and final code path that can
        // land write_file bytes on disk (recovery of a generation truncated
        // mid-write). Apply the same block WriteFileTool/handleStreamedToolCall
        // do so a truncated generation can't be used to sneak past the guard.
        if call.toolName == "write_file",
           let blocked = FileMutationSupport.writeGuardBlock(path: call.path, resolvedPath: resolvedPath) {
            // The tool-result text in `blocked` is what the MODEL reads — an
            // actionable recipe (read-then-edit_file, or append_file) — and
            // must stay verbatim (see FileMutationSupport.writeGuardBlock's
            // doc comment). This is a separate, user-facing notice that the
            // guard fired at all, so the human sees a harness-intervention
            // line even though the tool result itself keeps its own wording.
            frontend.harnessIntervention("blocked a write_file overwrite of \(call.path) — the model must use edit_file or append_file on an existing file instead.", severity: .warning)
            try? FileManager.default.removeItem(at: call.contentFile)
            return TruncatedWriteCommit(result: blocked, tail: "")
        }

        let targetURL = URL(fileURLWithPath: resolvedPath)
        let parentDir = targetURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return TruncatedWriteCommit(result: .error("Failed to prepare directory for \(call.path): \(error.localizedDescription)"), tail: "")
        }

        do {
            switch call.toolName {
            case "write_file":
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: call.contentFile)
                } else {
                    try FileManager.default.moveItem(at: call.contentFile, to: targetURL)
                }
                let finalText = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? tmpContent
                let tail = String(finalText.suffix(200))
                return TruncatedWriteCommit(
                    result: .success("Recovered partial write_file to \(call.path) (\(tmpContent.count) bytes). Generation was truncated; use append_file to add the remaining content."),
                    tail: tail
                )

            case "append_file":
                if let fh = try? FileHandle(forWritingTo: targetURL) {
                    defer { try? fh.close() }
                    try fh.seekToEnd()
                    try fh.write(contentsOf: Data(tmpContent.utf8))
                } else {
                    try tmpContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                }
                try? FileManager.default.removeItem(at: call.contentFile)
                let finalText = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? tmpContent
                let tail = String(finalText.suffix(200))
                return TruncatedWriteCommit(
                    result: .success("Recovered partial append_file to \(call.path) (\(tmpContent.count) bytes). Generation was truncated; use append_file again to add the remaining content."),
                    tail: tail
                )

            default:
                try? FileManager.default.removeItem(at: call.contentFile)
                return TruncatedWriteCommit(
                    result: .error("Truncated streamed tool '\(call.toolName)' cannot be recovered automatically; the partial content was discarded."),
                    tail: ""
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return TruncatedWriteCommit(
                result: .error("Failed to recover partial \(call.toolName) for \(call.path): \(error.localizedDescription)"),
                tail: ""
            )
        }
    }

    // MARK: - Streamed Tool Call Handling

    /// Handles a tool call whose content was streamed to a .tmp file during generation.
    /// Shows a diff to the user and applies the change if approved.
    func handleStreamedToolCall(_ call: StreamedToolCall) async -> ToolResult {
        // Same hard guard as executeToolCall: the orchestrator only ever has
        // task/todo/plan_file. Streamed write_file/edit_file/append_file calls
        // bypass executeToolCall entirely (their content is committed here,
        // straight from the .tmp file the streaming writer produced during
        // generation), so this path needs its own copy of the guard.
        if role == nil, !AgentLoop.orchestratorAllowedToolNames.contains(call.toolName) {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error("'\(call.toolName)' is not available to you directly — you are the orchestrator and only have task/todo/plan_file. Delegate this work instead, e.g. task(profile: \"executor\", description: \"...\") to write/edit files.")
        }

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(call.path)
        } catch {
            try? FileManager.default.removeItem(at: call.contentFile)
            return .error(error.localizedDescription)
        }

        // Hard write-guard: same decision FileMutationSupport applies for
        // WriteFileTool, applied here before the diff/approval flow so it
        // can't be bypassed by yolo/auto-edit approval modes. Large payloads
        // for write_file are streamed straight to disk via
        // replaceItemAt/moveItem below, completely bypassing WriteFileTool —
        // without this check that path would silently overwrite an existing
        // file with no guard at all.
        if call.toolName == "write_file",
           let blocked = FileMutationSupport.writeGuardBlock(path: call.path, resolvedPath: resolvedPath) {
            // See the identical comment in `commitTruncatedStreamedWrite` above:
            // `blocked`'s content is the model-facing recipe and stays untouched;
            // this is the separate user-facing notice that the guard fired.
            frontend.harnessIntervention("blocked a write_file overwrite of \(call.path) — the model must use edit_file or append_file on an existing file instead.", severity: .warning)
            try? FileManager.default.removeItem(at: call.contentFile)
            return blocked
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
            if let originalContent {
                var previewArguments = call.otherArgs
                previewArguments["path"] = call.path
                previewArguments["new_text"] = tmpContent

                let correctedPreviewArguments = await ParameterCorrectionService.correct(
                    toolName: "edit_file",
                    arguments: previewArguments,
                    workspaceRoot: permissions.effectiveWorkspaceRoot
                ).correctedArguments

                let oldText = (
                    correctedPreviewArguments["old_text"] as? String
                ) ?? (
                    correctedPreviewArguments["oldText"] as? String
                ) ?? (
                    correctedPreviewArguments["old"] as? String
                ) ?? (
                    correctedPreviewArguments["search_text"] as? String
                ) ?? (
                    correctedPreviewArguments["searchText"] as? String
                )

                if let oldText,
                   !oldText.isEmpty,
                   let range = originalContent.range(of: oldText) {
                    previewContent = originalContent.replacingCharacters(in: range, with: tmpContent)
                } else {
                    // If preview-time matching fails, keep the original content so we do not
                    // show a misleading full-file replacement diff for a localized edit.
                    previewContent = originalContent
                }
            } else {
                previewContent = tmpContent
            }
        case "append_file":
            previewContent = (originalContent ?? "") + tmpContent
        default:
            previewContent = tmpContent
        }

        let diff = DiffGenerator.generate(original: originalContent, new: previewContent, path: call.path)
        frontend.emitStatus("\n\(diff)")

        // Ask for approval
        let approval: (approved: Bool, suggestion: String?)
        if permissions.approvalMode == .yolo {
            approval = (true, nil)
        } else if permissions.approvalMode == .autoEdit && !["plan_file", "write_file", "edit_file", "append_file"].contains(call.toolName) {
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
                        frontend.harnessIntervention("auto-corrected the streamed edit_file's arguments — \(correction)")
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
                            frontend.harnessIntervention("retrying the streamed edit_file call with auto-corrected old_text instead of failing it.")
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

    // MARK: - Code Mode sub-call dispatch

    /// Dispatches one tool call with the same policy-check / destructive-
    /// approval / parameter-correction / watchdog / audit pipeline
    /// `executeToolCall` applies to a model-issued call. This is the sub-call
    /// entry point `execute_code` scripts use (see ExecuteCodeTool) — every
    /// `tools.write_file(...)` a script makes gets exactly the guarantees a
    /// direct model tool call would get, so code mode cannot be used to skip
    /// an approval prompt or a permission denial.
    ///
    /// Deliberately narrower than `executeToolCall`: it has no opinion on the
    /// calling turn's read/read-only loop detection, conversation history, or
    /// git-orchestration hookup — those are the top-level turn's concern, not
    /// a single sub-call's. A caller that needs modified/read-file tracking
    /// for files a script touched should parse them back out of the
    /// `execute_code` call's own `ToolResult`, the same way `task`'s digest
    /// already is (see the `call.name == "task"` handling in
    /// `executeToolCall`, mirrored for `execute_code` there too).
    func executeSubToolCall(name: String, arguments: [String: Any]) async -> ToolResult {
        guard name != "execute_code" else {
            return .error("execute_code cannot call itself.")
        }

        // `[String: Any]` is not Sendable; take an explicit unsafe snapshot
        // before crossing isolation boundaries below (matches the identical
        // workaround in executeToolCall's own tool-invocation path).
        nonisolated(unsafe) let isolatedArguments = arguments

        let call = ToolCallParser.ParsedToolCall(name: name, arguments: arguments)

        let targetPath = extractPolicyTargetPath(from: arguments)
        let policyDecision = permissions.evaluateToolPolicy(toolName: name, targetPath: targetPath)
        if case .denied(let denyReason) = policyDecision {
            let deniedResult = ToolResult.error(denyReason)
            await auditLogger?.logExecutionResult(
                toolName: name, arguments: isolatedArguments, approved: false,
                isError: true, resultPreview: deniedResult.content
            )
            return deniedResult
        }

        guard let tool = await registry.tool(named: name) else {
            let available = await registry.toolSignaturesForInference(filter: currentToolPromptFilter()).map(\.name)
            return .error(ToolCallErrorFormatter.unknownToolMessage(attempted: name, available: available))
        }

        let isDestructive = isDestructiveToolCall(call)
        let approval: (approved: Bool, suggestion: String?)
        if isDestructive {
            await hooks.emit(.permissionRequest(toolName: name, isPlanMode: mode == .plan))
            approval = await askForToolApproval(name: name, arguments: arguments, isPlanMode: mode == .plan)
            if approval.approved, mode == .plan {
                await setMode(.agent, taskType: .coding)
            }
        } else {
            approval = (true, nil)
        }

        guard approval.approved else {
            let deniedResult: ToolResult = if let suggestion = approval.suggestion {
                .error("User denied permission and provided this feedback/suggestion: \(suggestion)")
            } else {
                .error("User denied permission to execute this tool.")
            }
            if isDestructive {
                await auditLogger?.logExecutionResult(
                    toolName: name, arguments: isolatedArguments, approved: false,
                    isError: true, resultPreview: deniedResult.content
                )
            }
            return deniedResult
        }

        await hooks.emit(.preToolUse(toolName: name, argumentsPreview: serializedArgumentsPreview(arguments)))

        let correctionResult = await ParameterCorrectionService.correct(
            toolName: name, arguments: isolatedArguments, workspaceRoot: permissions.effectiveWorkspaceRoot
        )
        if correctionResult.wasCorrected {
            await auditLogger?.logParameterCorrection(
                toolName: name,
                originalArgumentsJSON: serializedArgumentsPreview(arguments),
                correctedArgumentsJSON: serializedArgumentsPreview(correctionResult.correctedArguments),
                corrections: correctionResult.corrections
            )
        }

        let missingRequiredArgs = LoopDetectionService.missingRequiredArgumentNames(
            required: tool.parameters.required,
            arguments: correctionResult.correctedArguments
        )

        var result: ToolResult
        if !missingRequiredArgs.isEmpty {
            result = .error(ToolCallErrorFormatter.missingRequiredMessage(
                toolName: name,
                missing: missingRequiredArgs,
                expected: Array(tool.parameters.properties?.keys ?? [String: PropertySchema]().keys),
                provided: Array(correctionResult.correctedArguments.keys)
            ))
        } else if isDestructive && dryRun {
            result = .success("Dry-run mode: skipped execution of destructive tool '\(name)'. Arguments: \(correctionResult.correctedArguments)")
        } else {
            nonisolated(unsafe) let isolatedExecutionArguments = correctionResult.correctedArguments
            let watchdogSeconds = ToolWatchdogConfig.seconds
            let invoke: @Sendable () async throws -> ToolResult = {
                if let progressTool = tool as? ProgressReportingTool {
                    return try await progressTool.execute(arguments: isolatedExecutionArguments) { _ in }
                }
                return try await tool.execute(arguments: isolatedExecutionArguments)
            }
            do {
                result = try await runWithToolWatchdog(seconds: watchdogSeconds, toolName: name, operation: invoke)
            } catch let timeout as ToolWatchdogTimeout {
                result = .error("Tool '\(timeout.toolName)' exceeded the \(Int(timeout.seconds))s watchdog and was cancelled.")
            } catch {
                result = .error("Tool execution failed: \(error.localizedDescription)")
            }
        }

        await hooks.emit(.postToolUse(toolName: name, isError: result.isError, resultPreview: String(result.content.prefix(220))))

        if isDestructive {
            await auditLogger?.logExecutionResult(
                toolName: name, arguments: isolatedArguments, approved: true,
                isError: result.isError, resultPreview: result.content
            )
        }

        return result
    }
}
