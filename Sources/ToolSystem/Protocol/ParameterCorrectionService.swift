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

            // Ensure path is relative (strip leading slash if present)
            if path.hasPrefix("/") {
                let relativePath = String(path.dropFirst())
                if !relativePath.isEmpty {
                    corrections.append("Converted absolute path to relative: '\(path)' -> '\(relativePath)'")
                    corrected["path"] = relativePath
                    path = relativePath
                }
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

        if path.hasPrefix("/") {
            let relativePath = String(path.dropFirst())
            if !relativePath.isEmpty {
                corrections.append("Converted absolute path to relative: '\(path)' -> '\(relativePath)'")
                corrected["path"] = relativePath
                path = relativePath
            }
        }

        if path.hasPrefix("./") {
            let strippedPath = String(path.dropFirst(2))
            if !strippedPath.isEmpty {
                corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                corrected["path"] = strippedPath
            }
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
                corrections.append("Auto-corrected old_text: '\(oldText.prefix(50))...' -> '\(bestMatch.prefix(50))...' (fuzzy match in file)")
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

    /// Find the best matching substring in the file content for the given search text.
    /// Uses line-by-line similarity to handle whitespace differences and minor edits.
    private static func findBestMatch(for searchText: String, in fileContent: String) -> String? {
        let searchLines = searchText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !searchLines.isEmpty else { return nil }

        let fileLines = fileContent.components(separatedBy: .newlines)
        var bestMatch: (score: Double, text: String)?

        // Sliding window: try to match search lines against consecutive file lines
        if fileLines.count >= searchLines.count {
            for startIdx in 0...(fileLines.count - searchLines.count) {
                let endIdx = min(startIdx + searchLines.count, fileLines.count)
                let candidateLines = Array(fileLines[startIdx..<endIdx])

                var matchScore: Double = 0
                for (i, searchLine) in searchLines.enumerated() {
                    if i < candidateLines.count {
                        let fileLine = candidateLines[i].trimmingCharacters(in: .whitespaces)
                        let similarity = lineSimilarity(searchLine, fileLine)
                        matchScore += similarity
                    }
                }
                let avgScore = matchScore / Double(searchLines.count)

                if avgScore > 0.7 {
                    let candidateText = candidateLines.joined(separator: "\n")
                    if bestMatch == nil || avgScore > bestMatch!.score {
                        bestMatch = (avgScore, candidateText)
                    }
                }
            }
        }

        // If no multi-line match found, try single-line matching
        if bestMatch == nil {
            for searchLine in searchLines {
                for fileLine in fileLines {
                    let trimmedFileLine = fileLine.trimmingCharacters(in: .whitespaces)
                    let similarity = lineSimilarity(searchLine, trimmedFileLine)
                    if similarity > 0.7 {
                        if bestMatch == nil || similarity > bestMatch!.score {
                            bestMatch = (similarity, fileLine)
                        }
                    }
                }
            }
        }

        return bestMatch?.text
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
                }
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

            if path.hasPrefix("/") {
                let relativePath = String(path.dropFirst())
                if !relativePath.isEmpty {
                    corrections.append("Converted absolute path to relative: '\(path)' -> '\(relativePath)'")
                    corrected["path"] = relativePath
                }
            }

            if path.hasPrefix("./") {
                let strippedPath = String(path.dropFirst(2))
                if !strippedPath.isEmpty {
                    corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                    corrected["path"] = strippedPath
                }
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

            if path.hasPrefix("/") {
                let relativePath = String(path.dropFirst())
                if !relativePath.isEmpty {
                    corrections.append("Converted absolute path to relative: '\(path)' -> '\(relativePath)'")
                    corrected["path"] = relativePath
                }
            }

            if path.hasPrefix("./") {
                let strippedPath = String(path.dropFirst(2))
                if !strippedPath.isEmpty {
                    corrections.append("Stripped leading './' from path: '\(path)' -> '\(strippedPath)'")
                    corrected["path"] = strippedPath
                }
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
        } else if var command = corrected["command"] as? String {
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
