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

    private enum PatchError: LocalizedError {
        case invalidHunkRange(start: Int, length: Int, fileLineCount: Int)
        case contextMismatch(start: Int)

        var errorDescription: String? {
            switch self {
            case .invalidHunkRange(let start, let length, let fileLineCount):
                return "Patch hunk range is out of bounds (start=\(start), length=\(length), file lines=\(fileLineCount))."
            case .contextMismatch(let start):
                return "Patch context mismatch at original line \(start). The file has changed or the diff is incorrect."
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
                lines = try applyHunk(hunk, to: lines)
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
        let oldLines: [String]
        let newLines: [String]
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
        var oldLines: [String] = []
        var newLines: [String] = []

        while startIndex < lines.count {
            let line = lines[startIndex]
            if line.hasPrefix("@@") || line.isEmpty && startIndex == lines.count - 1 {
                break
            } else if line.hasPrefix("+") {
                newLines.append(String(line.dropFirst()))
            } else if line.hasPrefix("-") {
                oldLines.append(String(line.dropFirst()))
            } else if line.hasPrefix(" ") {
                let contextLine = String(line.dropFirst())
                oldLines.append(contextLine)
                newLines.append(contextLine)
            } else if line.hasPrefix("\\ No newline at end of file") {
                // Ignore metadata marker.
            } else {
                break
            }
            startIndex += 1
        }

        guard oldCount == oldLines.count else {
            return nil
        }

        return Hunk(
            oldStart: oldStart,
            oldCount: oldCount,
            oldLines: oldLines,
            newLines: newLines
        )
    }

    private func applyHunk(_ hunk: Hunk, to lines: [String]) throws -> [String] {
        var result = lines
        let start = hunk.oldStart - 1
        let end = start + hunk.oldLines.count

        guard start >= 0, end <= result.count else {
            throw PatchError.invalidHunkRange(start: hunk.oldStart, length: hunk.oldLines.count, fileLineCount: result.count)
        }

        let currentSlice = Array(result[start..<end])
        guard currentSlice == hunk.oldLines else {
            throw PatchError.contextMismatch(start: hunk.oldStart)
        }

        result.replaceSubrange(start..<end, with: hunk.newLines)

        return result
    }
}
