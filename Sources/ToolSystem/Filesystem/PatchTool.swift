// Sources/ToolSystem/Filesystem/PatchTool.swift
// Apply unified diff patches to files

import Foundation

/// Applies a unified diff patch to a file.
public struct PatchTool: Tool {
    public let name = "patch"
    public let description = "Apply a unified diff patch to a file."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to patch (relative to workspace root)"),
            "diff": PropertySchema(type: "string", description: "Unified diff content to apply"),
        ],
        required: ["path", "diff"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }
        guard let diff = arguments["diff"] as? String else {
            return .error("Missing required argument: diff")
        }

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path)")
        }

        do {
            var lines = try String(contentsOfFile: resolvedPath, encoding: .utf8)
                .components(separatedBy: "\n")

            let hunks = parseDiff(diff)

            guard !hunks.isEmpty else {
                return .error("No valid diff hunks found in the provided diff")
            }

            // Apply hunks in reverse order to preserve line numbers
            for hunk in hunks.reversed() {
                lines = applyHunk(hunk, to: lines)
            }

            let result = lines.joined(separator: "\n")
            try result.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            return .success("Applied \(hunks.count) hunk(s) to \(path)")
        } catch {
            return .error("Failed to apply patch: \(error.localizedDescription)")
        }
    }

    // MARK: - Diff parsing

    private struct Hunk {
        let oldStart: Int // 1-indexed
        let oldCount: Int
        let additions: [(Int, String)]  // (line index, content)
        let deletions: [Int]             // line indices to remove
        let context: [(Int, String)]     // unchanged lines for validation
    }

    private func parseDiff(_ diff: String) -> [Hunk] {
        // Simplified unified diff parser
        var hunks: [Hunk] = []
        let lines = diff.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            // Look for hunk headers: @@ -old,count +new,count @@
            if line.hasPrefix("@@") {
                if let hunk = parseHunkHeader(line, lines: lines, startIndex: &i) {
                    hunks.append(hunk)
                }
            } else {
                i += 1
            }
        }

        return hunks
    }

    private func parseHunkHeader(_ header: String, lines: [String], startIndex: inout Int) -> Hunk? {
        // Parse @@ -old_start,old_count +new_start,new_count @@
        let pattern = #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
            startIndex += 1
            return nil
        }

        let oldStart = Int(header[Range(match.range(at: 1), in: header)!])!
        let oldCount = match.range(at: 2).location != NSNotFound
            ? Int(header[Range(match.range(at: 2), in: header)!])!
            : 1

        startIndex += 1
        var additions: [(Int, String)] = []
        var deletions: [Int] = []
        var context: [(Int, String)] = []
        var lineNum = oldStart

        while startIndex < lines.count {
            let line = lines[startIndex]
            if line.hasPrefix("@@") || line.isEmpty && startIndex == lines.count - 1 {
                break
            } else if line.hasPrefix("+") {
                additions.append((lineNum, String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                deletions.append(lineNum)
                lineNum += 1
            } else if line.hasPrefix(" ") {
                context.append((lineNum, String(line.dropFirst())))
                lineNum += 1
            } else {
                lineNum += 1
            }
            startIndex += 1
        }

        return Hunk(
            oldStart: oldStart,
            oldCount: oldCount,
            additions: additions,
            deletions: deletions,
            context: context
        )
    }

    private func applyHunk(_ hunk: Hunk, to lines: [String]) -> [String] {
        var result = lines

        // Remove deleted lines (in reverse to preserve indices)
        for idx in hunk.deletions.sorted().reversed() {
            let arrayIdx = idx - 1 // Convert to 0-indexed
            if arrayIdx >= 0 && arrayIdx < result.count {
                result.remove(at: arrayIdx)
            }
        }

        // Insert additions
        for (idx, content) in hunk.additions.sorted(by: { $0.0 < $1.0 }) {
            let arrayIdx = min(idx - 1, result.count)
            result.insert(content, at: arrayIdx)
        }

        return result
    }
}
