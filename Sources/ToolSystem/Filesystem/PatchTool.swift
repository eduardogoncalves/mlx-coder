// Sources/ToolSystem/Filesystem/PatchTool.swift
// Replaces: PatchTool ("patch") and EditFileTool ("edit_file").
// AppendFileTool ("append_file") is disabled but retained in its own file.

import Foundation

/// Modifies an existing file using a unified diff or a targeted search-and-replace.
public struct PatchFileTool: Tool {
    public let name = "patch_file"
    public let description = """
        Modify an existing file in-place. \
        ALWAYS include 'path' — it is required and must be the first argument. \
        Then specify exactly one mutation strategy: \
        supply 'diff' (unified diff) for changes that touch multiple non-adjacent locations, \
        or supply 'old_text' + 'new_text' for a single targeted substitution where old_text \
        appears exactly once. \
        Use write_file only when creating a brand-new file that does not yet exist. \
        Use read_file to inspect a file before editing.
        """
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(
                type: "string",
                description: "REQUIRED. Path to the file to modify (relative to workspace root). Must already exist. Always provide this — the tool will fail without it."
            ),
            "diff": PropertySchema(
                type: "string",
                description: """
                    Unified diff with one or more '@@ -old_start,old_count +new_start,new_count @@' hunks. \
                    Context lines (space-prefixed) and removed lines ('-') must match the file exactly. \
                    Header counts are advisory — body lines are the source of truth. \
                    Use this for multi-location changes. Omit when using old_text+new_text instead.
                    """
            ),
            "old_text": PropertySchema(
                type: "string",
                description: "Exact text to find and replace. Must appear exactly once in the file, including all whitespace and indentation. Add surrounding context lines to make it unique if needed. Required when not using 'diff'."
            ),
            "new_text": PropertySchema(
                type: "string",
                description: "Replacement text written in place of old_text. Required when using old_text."
            ),
        ],
        required: ["path"]
    )

    private let permissions: PermissionEngine

    // MARK: - Error types

    private enum PatchError: LocalizedError {
        case invalidHunkRange(start: Int, length: Int, fileLineCount: Int)
        case contextMismatch(start: Int, expected: [String], found: [String])

        var errorDescription: String? {
            switch self {
            case .invalidHunkRange(let start, let length, let fileLineCount):
                return "Hunk range out of bounds: start=\(start), old_count=\(length), " +
                       "but file only has \(fileLineCount) lines. Re-read the file and regenerate the diff."
            case .contextMismatch(let start, let expected, let found):
                let exp = expected.prefix(3).joined(separator: "\\n")
                let got = found.prefix(3).joined(separator: "\\n")
                return "Context mismatch at original line \(start): " +
                       "diff expects '\(exp)' but file has '\(got)'. " +
                       "Re-read the file and regenerate the diff."
            }
        }
    }

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path). patch_file only modifies existing files; use write_file to create new ones.")
        }

        let originalContent: String
        do {
            originalContent = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        } catch {
            return .error("Failed to read \(path): \(error.localizedDescription)")
        }

        // Unified diff mode
        if let diff = arguments["diff"] as? String, !diff.isEmpty {
            do {
                let patched = try Self.applyDiffString(diff, to: originalContent)
                try patched.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                let hunkCount = diff.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count
                return .success("Applied \(hunkCount) hunk(s) to \(path)")
            } catch {
                return .error("Failed to apply diff to \(path): \(error.localizedDescription)")
            }
        }

        // Search-and-replace mode
        if let oldText = arguments["old_text"] as? String,
           let newText = arguments["new_text"] as? String {
            let occurrences = originalContent.components(separatedBy: oldText).count - 1
            guard occurrences > 0 else {
                return .error("old_text not found in \(path). Make sure the text matches exactly, including whitespace.")
            }
            if occurrences > 1 {
                return .error("old_text found \(occurrences) times in \(path). It must be unique — add more surrounding context to old_text.")
            }
            let updated = originalContent.replacingOccurrences(of: oldText, with: newText)
            do {
                try updated.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
            } catch {
                return .error("Failed to write \(path): \(error.localizedDescription)")
            }
            return .success("Applied edit to \(path)")
        }

        return .error("patch_file requires either 'diff' (unified diff) or 'old_text'+'new_text' (search-and-replace).")
    }

    // MARK: - Public diff API (also used by the streaming preview handler)

    /// Applies a unified diff string to file content and returns the patched result.
    /// Header counts (old_count/new_count) are advisory — the parsed body is the source of truth.
    /// Throws a descriptive error on any parse or apply failure; nothing is silently dropped.
    public static func applyDiffString(_ diff: String, to content: String) throws -> String {
        var lines = content.components(separatedBy: "\n")
        let hunks = parseDiff(diff)
        guard !hunks.isEmpty else {
            throw NSError(
                domain: "PatchFileTool", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No diff hunks found. Provide a unified diff with '@@ -N,M +N,M @@' hunk headers."]
            )
        }
        for hunk in hunks.reversed() {
            lines = try applyHunk(hunk, to: lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Diff parsing

    private struct Hunk {
        let oldStart: Int   // 1-indexed
        let oldCount: Int   // derived from parsed body, not header
        let headerLine: String
        let oldLines: [String]
        let newLines: [String]
    }

    private static let hunkHeaderRegex = try! NSRegularExpression(
        pattern: #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
    )

    private static func parseDiff(_ diff: String) -> [Hunk] {
        var hunks: [Hunk] = []
        let lines = diff.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("@@") {
                if let hunk = parseHunkHeader(line, lines: lines, startIndex: &i) {
                    hunks.append(hunk)
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return hunks
    }

    private static func parseHunkHeader(_ header: String, lines: [String], startIndex: inout Int) -> Hunk? {
        guard let match = hunkHeaderRegex.firstMatch(
            in: header, range: NSRange(header.startIndex..., in: header)
        ) else {
            return nil
        }

        let oldStart = Int(header[Range(match.range(at: 1), in: header)!])!
        // oldCount from the header is only used to detect pure-insertion hunks (== 0).
        // The actual number of lines consumed is taken from the parsed body below.
        let declaredOldCount = match.range(at: 2).location != NSNotFound
            ? Int(header[Range(match.range(at: 2), in: header)!])!
            : 1

        startIndex += 1
        var oldLines: [String] = []
        var newLines: [String] = []

        while startIndex < lines.count {
            let line = lines[startIndex]
            if line.hasPrefix("@@") || (line.isEmpty && startIndex == lines.count - 1) {
                break
            } else if line.hasPrefix("+") {
                newLines.append(String(line.dropFirst()))
            } else if line.hasPrefix("-") {
                oldLines.append(String(line.dropFirst()))
            } else if line.hasPrefix(" ") {
                let ctx = String(line.dropFirst())
                oldLines.append(ctx)
                newLines.append(ctx)
            } else if line.hasPrefix("\\ No newline at end of file") {
                // standard git metadata marker, not a content line
            } else {
                break
            }
            startIndex += 1
        }

        // Use the declared count only to determine pure-insertion (0 old lines).
        // Otherwise use actual parsed body count so mis-counted headers still work.
        let effectiveOldCount = declaredOldCount == 0 ? 0 : oldLines.count

        return Hunk(
            oldStart: oldStart,
            oldCount: effectiveOldCount,
            headerLine: header,
            oldLines: oldLines,
            newLines: newLines
        )
    }

    private static func applyHunk(_ hunk: Hunk, to lines: [String]) throws -> [String] {
        var result = lines
        let start = hunk.oldStart - 1   // convert to 0-indexed

        // Pure insertion: old_count == 0 means insert newLines before line oldStart.
        // @@ -N,0 +N,M @@ in git convention inserts after line N-1 (= before line N).
        if hunk.oldCount == 0 {
            guard start >= 0, start <= result.count else {
                throw PatchError.invalidHunkRange(start: hunk.oldStart, length: 0, fileLineCount: result.count)
            }
            result.insert(contentsOf: hunk.newLines, at: start)
            return result
        }

        let end = start + hunk.oldLines.count
        guard start >= 0, end <= result.count else {
            throw PatchError.invalidHunkRange(start: hunk.oldStart, length: hunk.oldLines.count, fileLineCount: result.count)
        }

        let currentSlice = Array(result[start..<end])
        guard currentSlice == hunk.oldLines else {
            throw PatchError.contextMismatch(start: hunk.oldStart, expected: hunk.oldLines, found: currentSlice)
        }

        result.replaceSubrange(start..<end, with: hunk.newLines)
        return result
    }
}
