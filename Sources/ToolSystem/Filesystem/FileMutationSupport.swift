import Foundation

private extension StringProtocol {
    /// Like JavaScript's `String.trimEnd()`: drops trailing Unicode
    /// whitespace (which, notably, includes "\r" — so this alone is enough to
    /// absorb a CRLF file's trailing carriage return during line comparison).
    func trimmingTrailingWhitespace() -> String {
        String(self.reversed().drop(while: { $0.isWhitespace }).reversed())
    }
}

/// Shared file mutation helpers used by the generic write/edit tools and the
/// dedicated PLAN.MD tool so they apply the same validation, write, and diff behavior.
enum FileMutationSupport {
    static func writeContent(
        _ content: String,
        to path: String,
        permissions: PermissionEngine,
        blockExistingFile: Bool = false
    ) -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        if blockExistingFile, let blocked = writeGuardBlock(path: path, resolvedPath: resolvedPath) {
            return blocked
        }

        do {
            let parentDir = (resolvedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            let canonicalParent = URL(filePath: parentDir).standardized.resolvingSymlinksInPath().path()
            let canonicalWorkspaceRoot = URL(filePath: permissions.workspaceRoot)
                .standardized
                .resolvingSymlinksInPath()
                .path()
            let parentInsideWorkspace = canonicalParent == canonicalWorkspaceRoot
                || canonicalParent.hasPrefix(canonicalWorkspaceRoot + "/")
            guard parentInsideWorkspace else {
                return .error("Security violation: Parent directory path validation failed")
            }

            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let lineCount = content.components(separatedBy: "\n").count
            return .success("Wrote \(lineCount) lines to \(path)")
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }

    static func editContent(
        in path: String,
        oldText: String,
        newText: String,
        permissions: PermissionEngine
    ) -> ToolResult {
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
            let originalContent = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            let occurrences = originalContent.components(separatedBy: oldText).count - 1

            let newContent: String
            if occurrences == 1 {
                newContent = originalContent.replacingOccurrences(of: oldText, with: newText)
            } else if occurrences > 1 {
                return .error("old_text found \(occurrences) times in file. It must be unique. Add more surrounding context to old_text to make it unique.")
            } else {
                // Exact match failed. Try progressively fuzzier fallbacks, each
                // targeting a specific, common way a model's old_text drifts from
                // the file's actual bytes without the text meaning anything
                // different: CRLF line endings, Unicode lookalike punctuation, and
                // (broadest) per-line whitespace/lookalike drift across a
                // multi-line block. Every tier matches directly against the
                // untouched original bytes, so the file's real formatting is
                // preserved everywhere outside the edited span.
                switch try resolveFallbackMatch(oldText: oldText, in: originalContent) {
                case .unique(let matchedRange):
                    let adjustedNewText = matchLineEndings(of: newText, to: String(originalContent[matchedRange]))
                    newContent = originalContent.replacingCharacters(in: matchedRange, with: adjustedNewText)
                case .ambiguous(let count):
                    return .error("old_text found \(count) times in file. It must be unique. Add more surrounding context to old_text to make it unique.")
                case .notFound:
                    return .error("old_text not found in file. Make sure the text matches exactly, including whitespace.")
                }
            }

            try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let diff = generateUnifiedDiff(original: originalContent, updated: newContent, path: path)
            return .success("Applied edit to \(path)\n\(diff)")
        } catch {
            return .error("Failed to edit file: \(error.localizedDescription)")
        }
    }

    /// Finds occurrences of `oldText` in `content` where each `\n` in `oldText`
    /// is allowed to match either `\n` or `\r\n` in the file. Only meaningful for
    /// multi-line `oldText` — a single line can't straddle a line ending, so a
    /// plain substring search would already have found it.
    private static func eolTolerantMatches(of oldText: String, in content: String) throws -> [Range<String.Index>] {
        guard oldText.contains("\n") else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: oldText)
        let pattern = escaped.replacingOccurrences(of: "\n", with: "\\r?\\n")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        return matches.compactMap { Range($0.range, in: content) }
    }

    /// Outcome of running the fuzzy-match tiers below against one `old_text`.
    private enum FallbackMatchOutcome {
        case unique(Range<String.Index>)
        case ambiguous(count: Int)
        case notFound
    }

    /// Runs each fuzzy-match tier in order (most targeted first) and stops at
    /// the first tier that finds anything — a tier finding more than one match
    /// is reported as ambiguous rather than silently falling through to a
    /// broader tier, so a genuinely ambiguous edit still gets a "make it
    /// unique" error instead of an arbitrary pick.
    private static func resolveFallbackMatch(oldText: String, in content: String) throws -> FallbackMatchOutcome {
        let tiers: [[Range<String.Index>]] = [
            try eolTolerantMatches(of: oldText, in: content),
            normalizedCharacterMatches(of: oldText, in: content),
            lineBasedMatches(of: oldText, in: content)
        ]
        for matches in tiers {
            if matches.count == 1 { return .unique(matches[0]) }
            if matches.count > 1 { return .ambiguous(count: matches.count) }
        }
        return .notFound
    }

    /// Unicode lookalike punctuation → ASCII, so a model's "typographically
    /// autocorrected" old_text (curly quotes, en/em dashes, non-breaking
    /// spaces — the kind of substitution an LLM's tokenizer makes routinely
    /// when reproducing text from memory rather than copying it byte-for-byte)
    /// still matches source code that only ever contains the plain ASCII.
    /// Ported from qwen-code's `UNICODE_EQUIVALENT_MAP`
    /// (packages/core/src/utils/editHelper.ts) — same failure class as the
    /// CRLF mismatch above: the text reads identically but isn't byte-identical.
    private static let unicodeLookalikes: [Character: Character] = [
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-",
        "\u{2014}": "-", "\u{2015}": "-", "\u{2212}": "-",
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{00A0}": " ", "\u{2002}": " ", "\u{2003}": " ", "\u{2004}": " ",
        "\u{2005}": " ", "\u{2006}": " ", "\u{2007}": " ", "\u{2008}": " ",
        "\u{2009}": " ", "\u{200A}": " ", "\u{202F}": " ", "\u{205F}": " ",
        "\u{3000}": " "
    ]

    private static func normalizeLookalikeCharacters(_ text: String) -> String {
        String(text.map { unicodeLookalikes[$0] ?? $0 })
    }

    /// Finds `oldText` in `content` after mapping lookalike punctuation to
    /// ASCII on both sides. `normalizeLookalikeCharacters` maps exactly one
    /// `Character` to one `Character`, so normalized and original strings have
    /// identical Character counts in identical order — a match's Character
    /// offsets in the normalized string are valid Character offsets in the
    /// original string unchanged, no re-mapping needed.
    private static func normalizedCharacterMatches(of oldText: String, in content: String) -> [Range<String.Index>] {
        guard !oldText.isEmpty else { return [] }
        let normalizedOldText = normalizeLookalikeCharacters(oldText)
        let normalizedContent = normalizeLookalikeCharacters(content)
        guard normalizedOldText != oldText || normalizedContent != content else {
            // No lookalike characters on either side — identical to the
            // exact-match tier that already ran and failed; skip the redundant work.
            return []
        }

        var ranges: [Range<String.Index>] = []
        var searchStart = normalizedContent.startIndex
        while searchStart < normalizedContent.endIndex,
              let found = normalizedContent.range(of: normalizedOldText, range: searchStart..<normalizedContent.endIndex) {
            let startOffset = normalizedContent.distance(from: normalizedContent.startIndex, to: found.lowerBound)
            let length = normalizedContent.distance(from: found.lowerBound, to: found.upperBound)
            guard let originalStart = content.index(content.startIndex, offsetBy: startOffset, limitedBy: content.endIndex),
                  let originalEnd = content.index(originalStart, offsetBy: length, limitedBy: content.endIndex) else { break }
            ranges.append(originalStart..<originalEnd)
            searchStart = found.upperBound
        }
        return ranges
    }

    /// Locates `oldText` as a contiguous run of lines within `content`,
    /// tolerating — in order — an exact per-line match, a per-line match
    /// ignoring trailing whitespace (this alone also covers a CRLF file's
    /// trailing "\r", since Swift's `Character.isWhitespace` treats it as
    /// whitespace), and a per-line match after both trailing-whitespace and
    /// lookalike-punctuation normalization. This is the broadest, last-resort
    /// tier: a model reconstructing a multi-line block from memory routinely
    /// drifts on individual lines' trailing spaces or punctuation even when
    /// the overall structure is otherwise right. Ported from qwen-code's
    /// `findLineBasedMatch` (packages/core/src/utils/editHelper.ts), minus its
    /// "old_text has one extra trailing blank line" special case.
    private static func lineBasedMatches(of oldText: String, in content: String) -> [Range<String.Index>] {
        guard oldText.contains("\n") else { return [] }
        let haystackLines = content.components(separatedBy: "\n")
        let patternLines = oldText.components(separatedBy: "\n")
        guard !patternLines.isEmpty, patternLines.count <= haystackLines.count else { return [] }

        let passes: [(String) -> String] = [
            { $0 },
            { $0.trimmingTrailingWhitespace() },
            { normalizeLookalikeCharacters($0).trimmingTrailingWhitespace() }
        ]

        for transform in passes {
            let transformedPattern = patternLines.map(transform)
            var starts: [Int] = []
            for start in 0...(haystackLines.count - patternLines.count) {
                var isMatch = true
                for offset in 0..<patternLines.count where transform(haystackLines[start + offset]) != transformedPattern[offset] {
                    isMatch = false
                    break
                }
                if isMatch { starts.append(start) }
            }
            if !starts.isEmpty {
                return starts.compactMap { lineSequenceRange(startLine: $0, count: patternLines.count, lines: haystackLines, in: content) }
            }
        }
        return []
    }

    /// The `Range<String.Index>` in `content` spanning lines
    /// `[startLine, startLine + count)` of `lines` (both derived from the same
    /// `content.components(separatedBy: "\n")` split), excluding the final
    /// line's own trailing "\n".
    private static func lineSequenceRange(startLine: Int, count: Int, lines: [String], in content: String) -> Range<String.Index>? {
        guard count > 0 else { return nil }
        var charOffset = 0
        for i in 0..<startLine { charOffset += lines[i].count + 1 }
        guard let startIndex = content.index(content.startIndex, offsetBy: charOffset, limitedBy: content.endIndex) else { return nil }
        var length = 0
        for i in startLine..<(startLine + count) {
            length += lines[i].count
            if i < startLine + count - 1 { length += 1 }
        }
        guard let endIndex = content.index(startIndex, offsetBy: length, limitedBy: content.endIndex) else { return nil }
        return startIndex..<endIndex
    }

    /// Rewrites `text`'s line endings to match `referenceText`'s convention, so
    /// inserted content doesn't leave a CRLF file with a mix of `\n`-only lines
    /// where a model's freshly generated `new_text` landed.
    private static func matchLineEndings(of text: String, to referenceText: String) -> String {
        guard referenceText.contains("\r\n") else { return text }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Reads a file's full contents back. Returns a clear "not found" result
    /// (not an error a caller needs to special-case) rather than throwing,
    /// since "the plan doesn't exist yet" is an expected, common outcome for
    /// callers checking whether a plan has been written before delegating.
    static func readContent(from path: String, permissions: PermissionEngine) -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validateReadPath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path)")
        }

        do {
            let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            return .success(content)
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }

    /// Decides whether the `write_file` hard write-guard should reject a write
    /// to `resolvedPath`, returning the actionable-recipe error to surface to
    /// the model. Returns `nil` when the write may proceed — either because
    /// the target doesn't exist yet (a genuine create), or because the caller
    /// didn't opt into the guard at all (see `writeContent`'s
    /// `blockExistingFile` parameter, which `PlanFileTool` deliberately leaves
    /// `false` so it can keep overwriting the fixed PLAN.MD document).
    ///
    /// This is the single source of truth for the block decision + message so
    /// all three code paths that can land bytes on disk for `write_file` —
    /// `WriteFileTool` (via `writeContent` above), the large-payload streamed
    /// commit in `AgentLoop.handleStreamedToolCall`, and the truncated-write
    /// recovery in `AgentLoop.commitTruncatedStreamedWrite` — apply the exact
    /// same rule instead of three copies that could drift out of sync.
    ///
    /// The recipe deliberately does not just say "use edit_file instead":
    /// `edit_file` requires an exact, unique `old_text` the model doesn't have
    /// yet for a file it hasn't read, so the message spells out the two real
    /// next steps (read-then-edit_file, or append_file) with their exact
    /// argument names.
    static func writeGuardBlock(path: String, resolvedPath: String) -> ToolResult? {
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return nil }
        return .error("""
            \(path) already exists. write_file will not overwrite it by default, because replacing the whole file destroys any unrelated content a small model didn't intend to touch. Choose one:
            - Read \(path), then call edit_file with path: "\(path)", old_text: <the exact snippet to replace>, new_text: <its replacement> for a targeted change (preferred).
            - Or call append_file with path: "\(path)", content: <text to add> to add content at the end without touching the rest.
            - Or, if you truly intend to replace the entire file, call write_file again with the same path, content, and overwrite: true.
            """)
    }

    static func generateUnifiedDiff(original: String, updated: String, path: String) -> String {
        let origLines = original.components(separatedBy: "\n")
        let newLines = updated.components(separatedBy: "\n")

        var lo = 0
        while lo < origLines.count && lo < newLines.count && origLines[lo] == newLines[lo] {
            lo += 1
        }

        var origHi = origLines.count
        var newHi = newLines.count
        while origHi > lo && newHi > lo && origLines[origHi - 1] == newLines[newHi - 1] {
            origHi -= 1
            newHi -= 1
        }

        guard lo < origHi || lo < newHi else { return "(no changes)" }

        let ctx = 3
        let hunkStart = max(0, lo - ctx)
        let hunkOrigEnd = min(origLines.count, origHi + ctx)

        let leadingCtx = lo - hunkStart
        let deletedCount = origHi - lo
        let addedCount = newHi - lo
        let trailingCtx = hunkOrigEnd - origHi

        let totalOrig = leadingCtx + deletedCount + trailingCtx
        let totalNew = leadingCtx + addedCount + trailingCtx

        var hunk = "@@ -\(hunkStart + 1),\(totalOrig) +\(hunkStart + 1),\(totalNew) @@\n"

        for l in hunkStart..<lo { hunk += " \(origLines[l])\n" }
        for l in lo..<origHi { hunk += "-\(origLines[l])\n" }
        for l in lo..<newHi { hunk += "+\(newLines[l])\n" }
        for l in origHi..<hunkOrigEnd { hunk += " \(origLines[l])\n" }

        return "--- a/\(path)\n+++ b/\(path)\n\(hunk)"
    }
}
