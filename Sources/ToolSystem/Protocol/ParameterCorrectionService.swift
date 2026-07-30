// Sources/ToolSystem/Protocol/ParameterCorrectionService.swift
// Automatically corrects common tool call parameter errors without LLM involvement

import Foundation

/// Result of a parameter correction attempt.
public struct ParameterCorrectionResult: @unchecked Sendable {
    /// Whether any corrections were applied.
    public let wasCorrected: Bool
    /// The corrected arguments (may be same as input if no corrections needed).
    public let correctedArguments: [String: Any]
    /// Human-readable descriptions of corrections applied.
    public let corrections: [String]

    public init(wasCorrected: Bool, correctedArguments: [String: Any], corrections: [String]) {
        self.wasCorrected = wasCorrected
        self.correctedArguments = correctedArguments
        self.corrections = corrections
    }

    /// No corrections needed — returns input unchanged.
    public static func unchanged(_ arguments: [String: Any]) -> ParameterCorrectionResult {
        ParameterCorrectionResult(wasCorrected: false, correctedArguments: arguments, corrections: [])
    }
}

/// Rewrites a model-emitted absolute path so the workspace is the implicit root.
///
/// - If the path lives inside `workspaceRoot`, strip the prefix to make it
///   relative — paths like `<workspaceRoot>/src/main.swift` become `src/main.swift`.
/// - If the path is `~`-prefixed, expand it first and then re-apply the same
///   inside/outside check.
/// - If the absolute path is outside `workspaceRoot`, leave it untouched so
///   `PermissionEngine.validatePath` raises `pathOutsideWorkspace` with a
///   clear error pointing at the real workspace root. Returning a garbage
///   relative path (the old `dropFirst()` trick) was worse because it
///   silently rerouted the call to a non-existent subdirectory.
enum WorkspacePathRewrite {
    static func rewriteIfPossible(_ path: String, workspaceRoot: String) -> (newPath: String, message: String)? {
        guard !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }

        let normalizedInput = URL(filePath: expanded).standardized.path()
        let normalizedRoot = URL(filePath: workspaceRoot).standardized.path()
        let rootWithSlash = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"

        if normalizedInput == normalizedRoot {
            return (".", "Rewrote workspace-root absolute path '\(path)' to '.'")
        }

        if normalizedInput.hasPrefix(rootWithSlash) {
            let relative = String(normalizedInput.dropFirst(rootWithSlash.count))
            if !relative.isEmpty {
                return (relative, "Rewrote absolute path '\(path)' to workspace-relative '\(relative)'")
            }
        }

        // Path lives outside the workspace; do not corrupt it — let the
        // permission engine surface a meaningful error.
        return nil
    }
}

/// Strips a redundant leading path segment that duplicates the workspace
/// root's own directory name — but ONLY when doing so actually resolves to an
/// existing file while the original path does not.
///
/// This fixes isolated sub-agents whose root is e.g. `<repo>/ChatStreamingAPI`
/// but which keep using the parent orchestrator's `ChatStreamingAPI/Program.cs`
/// convention, which resolves to the non-existent
/// `<repo>/ChatStreamingAPI/ChatStreamingAPI/Program.cs` and produces a stream
/// of "File not found" errors. The rewrite is evidence-gated: it only fires
/// when the stripped path exists on disk and the original does not, so it can
/// never clobber a genuine same-named subdirectory.
enum RedundantRootPrefixRewrite {
    static func rewriteIfResolvable(_ path: String, workspaceRoot: String) -> (newPath: String, message: String)? {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath, !workspaceRoot.isEmpty else { return nil }
        let rootBase = (workspaceRoot as NSString).lastPathComponent
        guard !rootBase.isEmpty else { return nil }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1, components.first == rootBase else { return nil }

        let stripped = components.dropFirst().joined(separator: "/")
        guard !stripped.isEmpty else { return nil }

        let fm = FileManager.default
        let originalResolved = (workspaceRoot as NSString).appendingPathComponent(path)
        let strippedResolved = (workspaceRoot as NSString).appendingPathComponent(stripped)
        guard !fm.fileExists(atPath: originalResolved), fm.fileExists(atPath: strippedResolved) else { return nil }

        return (stripped, "Rewrote '\(path)' to '\(stripped)' (stripped redundant workspace-root prefix; original path did not exist)")
    }
}

/// Service that detects and fixes common tool call parameter errors.
///
/// This service applies deterministic, safe corrections to fix formatting/syntactic issues
/// without modifying user intent. All corrections are logged for auditability.
public struct ParameterCorrectionService: Sendable {

    /// Attempt to correct parameters for a given tool call.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool being called.
    ///   - arguments: The raw arguments from the model output.
    ///   - workspaceRoot: The workspace root for path resolution.
    /// - Returns: A correction result with corrected arguments and a list of corrections applied.
    public static func correct(
        toolName: String,
        arguments: [String: Any],
        workspaceRoot: String
    ) async -> ParameterCorrectionResult {
        switch toolName {
        case "write_file", "append_file":
            return await correctFileWriteTool(arguments: arguments, workspaceRoot: workspaceRoot)
        case "edit_file":
            return await correctEditFileTool(arguments: arguments, workspaceRoot: workspaceRoot)
        case "read_file":
            return await correctReadFileTool(arguments: arguments, workspaceRoot: workspaceRoot)
        case "patch":
            return await correctPatchTool(arguments: arguments, workspaceRoot: workspaceRoot)
        case "list_dir":
            return await correctListDirTool(arguments: arguments, workspaceRoot: workspaceRoot)
        case "bash":
            return correctBashTool(arguments: arguments)
        default:
            return .unchanged(arguments)
        }
    }

    // MARK: - File Write Tools (write_file, append_file)

    private static func correctFileWriteTool(
        arguments: [String: Any],
        workspaceRoot: String
    ) async -> ParameterCorrectionResult {
        var corrected = arguments
        var corrections: [String] = []

        // Normalize path separators
        if var path = corrected["path"] as? String {
            let originalPath = path
            path = path.replacingOccurrences(of: "\\", with: "/")
            if path != originalPath {
                corrections.append("Normalized path separators: '\(originalPath)' -> '\(path)'")
                corrected["path"] = path
            }

            // Rewrite absolute paths that point inside the workspace to be
            // workspace-relative. Paths pointing outside the workspace are
            // left alone so the permission engine returns a clear error.
            if let rewrite = WorkspacePathRewrite.rewriteIfPossible(path, workspaceRoot: workspaceRoot) {
                corrections.append(rewrite.message)
                corrected["path"] = rewrite.newPath
                path = rewrite.newPath
            }

            // Strip leading "./" for consistency
            if path.hasPrefix("./") {
                let strippedPath = String(path.dropFirst(2))
                if !strippedPath.isEmpty {
                    corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                    corrected["path"] = strippedPath
                }
            }
        }

        // Canonicalize common content aliases used by some models.
        if corrected["content"] == nil {
            let contentAliases = ["file_content", "contents", "text", "body", "fileContent"]
            if let matchedAlias = contentAliases.first(where: { corrected[$0] is String }),
               let aliasedContent = corrected[matchedAlias] as? String {
                corrected["content"] = aliasedContent
                corrections.append("Mapped '\(matchedAlias)' to 'content'")
            }
        }

        // Ensure content is present (empty string is valid for write_file)
        if corrected["content"] == nil {
            corrections.append("Added missing 'content' parameter (empty string)")
            corrected["content"] = ""
        }

        return ParameterCorrectionResult(
            wasCorrected: !corrections.isEmpty,
            correctedArguments: corrected,
            corrections: corrections
        )
    }

    // MARK: - Edit File Tool

    private static func correctEditFileTool(
        arguments: [String: Any],
        workspaceRoot: String
    ) async -> ParameterCorrectionResult {
        var corrected = arguments
        var corrections: [String] = []

        // Canonicalize common argument aliases produced by models.
        if corrected["path"] == nil {
            let pathAliases = ["file_path", "filePath", "filepath", "target_path"]
            if let matchedAlias = pathAliases.first(where: { corrected[$0] is String }),
               let aliasedPath = corrected[matchedAlias] as? String {
                corrected["path"] = aliasedPath
                corrections.append("Mapped '\(matchedAlias)' to 'path'")
            }
        }

        if corrected["old_text"] == nil {
            let oldTextAliases = ["oldText", "old", "search_text", "searchText", "target_text", "text_to_replace"]
            if let matchedAlias = oldTextAliases.first(where: { corrected[$0] is String }),
               let aliasedOldText = corrected[matchedAlias] as? String {
                corrected["old_text"] = aliasedOldText
                corrections.append("Mapped '\(matchedAlias)' to 'old_text'")
            }
        }

        if corrected["new_text"] == nil {
            let newTextAliases = ["newText", "replacement", "replacement_text", "replace_with", "text"]
            if let matchedAlias = newTextAliases.first(where: { corrected[$0] is String }),
               let aliasedNewText = corrected[matchedAlias] as? String {
                corrected["new_text"] = aliasedNewText
                corrections.append("Mapped '\(matchedAlias)' to 'new_text'")
            }
        }

        // Normalize path separators
        guard var path = corrected["path"] as? String else {
            if corrected["old_text"] == nil {
                corrected["old_text"] = ""
            }
            if corrected["new_text"] == nil {
                corrected["new_text"] = ""
            }
            return ParameterCorrectionResult(
                wasCorrected: !corrections.isEmpty,
                correctedArguments: corrected,
                corrections: corrections
            )
        }

        let originalPath = path
        path = path.replacingOccurrences(of: "\\", with: "/")
        if path != originalPath {
            corrections.append("Normalized path separators: '\(originalPath)' -> '\(path)'")
            corrected["path"] = path
        }

        if let rewrite = WorkspacePathRewrite.rewriteIfPossible(path, workspaceRoot: workspaceRoot) {
            corrections.append(rewrite.message)
            corrected["path"] = rewrite.newPath
            path = rewrite.newPath
        }

        if path.hasPrefix("./") {
            let strippedPath = String(path.dropFirst(2))
            if !strippedPath.isEmpty {
                corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                corrected["path"] = strippedPath
                path = strippedPath
            }
        }

        if let rewrite = RedundantRootPrefixRewrite.rewriteIfResolvable(path, workspaceRoot: workspaceRoot) {
            corrections.append(rewrite.message)
            corrected["path"] = rewrite.newPath
            path = rewrite.newPath
        }

        // Ensure old_text and new_text are present
        guard let oldText = corrected["old_text"] as? String, !oldText.isEmpty else {
            if corrected["old_text"] == nil {
                corrections.append("Added missing 'old_text' parameter (empty string)")
                corrected["old_text"] = ""
            }
            if corrected["new_text"] == nil {
                corrections.append("Added missing 'new_text' parameter (empty string)")
                corrected["new_text"] = ""
            }
            return ParameterCorrectionResult(
                wasCorrected: !corrections.isEmpty,
                correctedArguments: corrected,
                corrections: corrections
            )
        }

        guard let newText = corrected["new_text"] as? String else {
            corrections.append("Added missing 'new_text' parameter (empty string)")
            corrected["new_text"] = ""
            return ParameterCorrectionResult(
                wasCorrected: !corrections.isEmpty,
                correctedArguments: corrected,
                corrections: corrections
            )
        }

        // Try fuzzy matching: read the file and find the closest match for old_text
        let resolvedPath = (path as NSString).isAbsolutePath
            ? path
            : (workspaceRoot as NSString).appendingPathComponent(path)

        if FileManager.default.fileExists(atPath: resolvedPath),
           let fileContent = try? String(contentsOfFile: resolvedPath, encoding: .utf8) {
            
            // If exact match exists, no correction needed
            if fileContent.contains(oldText) {
                return ParameterCorrectionResult(
                    wasCorrected: !corrections.isEmpty,
                    correctedArguments: corrected,
                    corrections: corrections
                )
            }

            // Try to find the best matching text in the file
            if let bestMatch = findBestMatch(for: oldText, in: fileContent) {
                let normalizedBestMatch = normalizeEditText(bestMatch)
                let normalizedNewText = normalizeEditText(newText)

                // Never rewrite old_text into the replacement text. That produces
                // misleading previews and can turn a search/replace into a no-op.
                guard normalizedBestMatch != normalizedNewText else {
                    return ParameterCorrectionResult(
                        wasCorrected: !corrections.isEmpty,
                        correctedArguments: corrected,
                        corrections: corrections
                    )
                }

                let searchLineCount = oldText.components(separatedBy: .newlines).count
                corrections.append("Auto-corrected old_text to nearest unique match in file (\(searchLineCount)-line search): [\(auditPreview(bestMatch))]")
                corrected["old_text"] = bestMatch
                corrected["new_text"] = newText
            }
        }

        return ParameterCorrectionResult(
            wasCorrected: !corrections.isEmpty,
            correctedArguments: corrected,
            corrections: corrections
        )
    }

    /// Minimum average line similarity for a window to be considered a match.
    private static let matchThreshold = 0.7
    /// A runner-up within this score of the best candidate makes the match
    /// ambiguous — two different file locations fit about equally well, so we
    /// cannot know which one the model meant and must refuse rather than guess.
    private static let ambiguityMargin = 0.05

    /// Find the best matching substring in the file content for the given search
    /// text, or nil when there is no confident, unambiguous match.
    ///
    /// Safety rules — added after a fuzzy "correction" silently corrupted a
    /// `.csproj` (it collapsed a 3-line `<ItemGroup>` block onto the single bare
    /// `<ItemGroup>` line and then let the multi-line replacement land there,
    /// duplicating structure and orphaning tags):
    ///  - A multi-line `searchText` may ONLY match a window with the same line
    ///    count. It is never repaired into a single file line — that is exactly
    ///    what changed the shape of the file and mangled it.
    ///  - When two *different* locations match about equally well the choice is
    ///    ambiguous; we return nil so `edit_file` fails cleanly with
    ///    "old_text not found" (prompting an exact retry) instead of editing the
    ///    wrong region.
    /// Uses line-by-line similarity to tolerate whitespace/indentation drift.
    private static func findBestMatch(for searchText: String, in fileContent: String) -> String? {
        let searchLines = searchText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !searchLines.isEmpty else { return nil }

        let fileLines = fileContent.components(separatedBy: .newlines)
        let windowSize = searchLines.count
        var scored: [(score: Double, text: String)] = []

        // Sliding window: match the search lines against a same-line-count run
        // of consecutive file lines.
        if fileLines.count >= windowSize {
            for startIdx in 0...(fileLines.count - windowSize) {
                let candidateLines = Array(fileLines[startIdx..<(startIdx + windowSize)])

                var matchScore: Double = 0
                for (i, searchLine) in searchLines.enumerated() {
                    let fileLine = candidateLines[i].trimmingCharacters(in: .whitespaces)
                    matchScore += lineSimilarity(searchLine, fileLine)
                }
                let avgScore = matchScore / Double(windowSize)

                if avgScore > matchThreshold {
                    scored.append((avgScore, candidateLines.joined(separator: "\n")))
                }
            }
        }

        // Single-line fallback ONLY when the search text is itself a single
        // line. A multi-line old_text must never collapse onto one file line.
        if scored.isEmpty && windowSize == 1 {
            let searchLine = searchLines[0]
            for fileLine in fileLines {
                let similarity = lineSimilarity(searchLine, fileLine.trimmingCharacters(in: .whitespaces))
                if similarity > matchThreshold {
                    scored.append((similarity, fileLine))
                }
            }
        }

        return bestUnambiguousMatch(from: scored)
    }

    /// Picks the highest-scoring candidate, but only if no *other* distinct
    /// candidate scores within `ambiguityMargin` of it. Identical-text
    /// candidates (the same block appearing more than once) are not treated as
    /// ambiguous here — `FileMutationSupport.editContent`'s own uniqueness check
    /// rejects a non-unique `old_text` downstream with a clear message.
    private static func bestUnambiguousMatch(from scored: [(score: Double, text: String)]) -> String? {
        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }
        let ambiguousRivals = scored.contains {
            $0.text != best.text && $0.score >= best.score - ambiguityMargin
        }
        return ambiguousRivals ? nil : best.text
    }

    /// Compact, non-misleading preview of a (possibly multi-line) correction
    /// target for the audit log. The previous `.prefix(50)` rendering hid the
    /// fact that a multi-line block was being substituted, so a destructive
    /// rewrite could not be audited from its log line.
    private static func auditPreview(_ text: String, maxChars: Int = 80) -> String {
        let lines = text.components(separatedBy: .newlines)
        let firstLine = lines.first ?? text
        let clipped = firstLine.count > maxChars ? String(firstLine.prefix(maxChars)) + "…" : firstLine
        return lines.count > 1 ? "\(clipped) …(+\(lines.count - 1) more line(s))" : clipped
    }

    /// Calculate similarity between two strings (0.0 to 1.0).
    /// Uses a simple character-level approach: common characters / max length.
    private static func lineSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1.0 }

        // Use character bigrams for better matching of code-like text
        let bigramsA = Set(bigrams(of: a))
        let bigramsB = Set(bigrams(of: b))
        
        let intersection = bigramsA.intersection(bigramsB).count
        let union = bigramsA.union(bigramsB).count
        
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    /// Generate character bigrams from a string.
    private static func bigrams(of string: String) -> [String] {
        guard string.count >= 2 else { return [string] }
        var bigrams: [String] = []
        let chars = Array(string)
        for i in 0..<(chars.count - 1) {
            bigrams.append(String(chars[i...i+1]))
        }
        return bigrams
    }

    private static func normalizeEditText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Read File Tool

    private static func correctReadFileTool(
        arguments: [String: Any],
        workspaceRoot: String
    ) async -> ParameterCorrectionResult {
        var corrected = arguments
        var corrections: [String] = []

        // Normalize path separators
        if var path = corrected["path"] as? String {
            let originalPath = path
            path = path.replacingOccurrences(of: "\\", with: "/")
            if path != originalPath {
                corrections.append("Normalized path separators: '\(originalPath)' -> '\(path)'")
                corrected["path"] = path
            }

            // Keep absolute paths intact for read_file. Permission checks decide what is allowed.
            if !path.hasPrefix("/") && path.hasPrefix("./") {
                let strippedPath = String(path.dropFirst(2))
                if !strippedPath.isEmpty {
                    corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                    corrected["path"] = strippedPath
                    path = strippedPath
                }
            }

            if let rewrite = RedundantRootPrefixRewrite.rewriteIfResolvable(path, workspaceRoot: workspaceRoot) {
                corrections.append(rewrite.message)
                corrected["path"] = rewrite.newPath
            }
        }

        // Validate and correct line numbers if present
        if let startLine = corrected["start_line"] {
            if let startInt = startLine as? Int {
                if startInt < 1 {
                    corrections.append("Corrected invalid start_line \(startInt) to 1")
                    corrected["start_line"] = 1
                }
            } else if let startString = startLine as? String, let parsed = Int(startString) {
                if parsed < 1 {
                    corrections.append("Converted start_line from string '\(startString)' to integer and corrected to 1")
                    corrected["start_line"] = 1
                } else {
                    corrections.append("Converted start_line from string '\(startString)' to integer \(parsed)")
                    corrected["start_line"] = parsed
                }
            }
        }

        if let endLine = corrected["end_line"] {
            if let endInt = endLine as? Int {
                if endInt < 1 {
                    corrections.append("Corrected invalid end_line \(endInt) to 1")
                    corrected["end_line"] = 1
                }
            } else if let endString = endLine as? String, let parsed = Int(endString) {
                if parsed < 1 {
                    corrections.append("Converted end_line from string '\(endString)' to integer and corrected to 1")
                    corrected["end_line"] = 1
                } else {
                    corrections.append("Converted end_line from string '\(endString)' to integer \(parsed)")
                    corrected["end_line"] = parsed
                }
            }
        }

        // Ensure start_line <= end_line if both present
        if let startLine = corrected["start_line"] as? Int,
           let endLine = corrected["end_line"] as? Int,
           startLine > endLine {
            corrections.append("Swapped start_line (\(startLine)) and end_line (\(endLine)) because start > end")
            corrected["start_line"] = endLine
            corrected["end_line"] = startLine
        }

        return ParameterCorrectionResult(
            wasCorrected: !corrections.isEmpty,
            correctedArguments: corrected,
            corrections: corrections
        )
    }

    // MARK: - Patch Tool

    private static func correctPatchTool(
        arguments: [String: Any],
        workspaceRoot: String
    ) async -> ParameterCorrectionResult {
        var corrected = arguments
        var corrections: [String] = []

        // Normalize path separators
        if var path = corrected["path"] as? String {
            let originalPath = path
            path = path.replacingOccurrences(of: "\\", with: "/")
            if path != originalPath {
                corrections.append("Normalized path separators: '\(originalPath)' -> '\(path)'")
                corrected["path"] = path
            }

            if let rewrite = WorkspacePathRewrite.rewriteIfPossible(path, workspaceRoot: workspaceRoot) {
                corrections.append(rewrite.message)
                corrected["path"] = rewrite.newPath
                path = rewrite.newPath
            }

            if path.hasPrefix("./") {
                let strippedPath = String(path.dropFirst(2))
                if !strippedPath.isEmpty {
                    corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                    corrected["path"] = strippedPath
                    path = strippedPath
                }
            }

            if let rewrite = RedundantRootPrefixRewrite.rewriteIfResolvable(path, workspaceRoot: workspaceRoot) {
                corrections.append(rewrite.message)
                corrected["path"] = rewrite.newPath
            }
        }

        // Ensure patch is present
        if corrected["patch"] == nil {
            corrections.append("Added missing 'patch' parameter (empty string)")
            corrected["patch"] = ""
        }

        return ParameterCorrectionResult(
            wasCorrected: !corrections.isEmpty,
            correctedArguments: corrected,
            corrections: corrections
        )
    }

    // MARK: - List Directory Tool

    private static func correctListDirTool(
        arguments: [String: Any],
        workspaceRoot: String
    ) async -> ParameterCorrectionResult {
        var corrected = arguments
        var corrections: [String] = []

        // Normalize path separators
        if var path = corrected["path"] as? String {
            let originalPath = path
            path = path.replacingOccurrences(of: "\\", with: "/")
            if path != originalPath {
                corrections.append("Normalized path separators: '\(originalPath)' -> '\(path)'")
                corrected["path"] = path
            }

            if let rewrite = WorkspacePathRewrite.rewriteIfPossible(path, workspaceRoot: workspaceRoot) {
                corrections.append(rewrite.message)
                corrected["path"] = rewrite.newPath
                path = rewrite.newPath
            }

            if path.hasPrefix("./") {
                let strippedPath = String(path.dropFirst(2))
                if !strippedPath.isEmpty {
                    corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                    corrected["path"] = strippedPath
                    path = strippedPath
                }
            }

            if let rewrite = RedundantRootPrefixRewrite.rewriteIfResolvable(path, workspaceRoot: workspaceRoot) {
                corrections.append(rewrite.message)
                corrected["path"] = rewrite.newPath
            }
        }

        return ParameterCorrectionResult(
            wasCorrected: !corrections.isEmpty,
            correctedArguments: corrected,
            corrections: corrections
        )
    }

    // MARK: - Bash Tool

    private static func correctBashTool(
        arguments: [String: Any]
    ) -> ParameterCorrectionResult {
        var corrected = arguments
        var corrections: [String] = []

        // Ensure command is present
        if corrected["command"] == nil {
            corrections.append("Added missing 'command' parameter (empty string)")
            corrected["command"] = ""
        } else if let command = corrected["command"] as? String {
            // Trim whitespace from command
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != command {
                corrections.append("Trimmed whitespace from command")
                corrected["command"] = trimmed
            }
        }

        return ParameterCorrectionResult(
            wasCorrected: !corrections.isEmpty,
            correctedArguments: corrected,
            corrections: corrections
        )
    }
}
