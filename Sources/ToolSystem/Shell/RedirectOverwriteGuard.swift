// Sources/ToolSystem/Shell/RedirectOverwriteGuard.swift
// Shell hardening: block truncating write operators (`>`, `tee`, `dd`) from
// silently overwriting a file that already exists in the workspace — the
// shell equivalent of write_file's hard write-guard (see FileMutationSupport
// .writeGuardBlock). `cat > existing_file <<'EOF' ... EOF`, `... | tee
// existing_file`, and `dd of=existing_file` are shell idioms a small model
// reaches for just as often as write_file, and all three bypass the tool
// layer (and therefore the write_file guard) entirely.

import Foundation

/// Static helper used by `BashTool` to detect a truncating write — a shell
/// redirect (`>`, `N>`, or `&>`), a `tee` invocation without `-a`/`--append`,
/// or a `dd of=FILE` invocation — whose target resolves to a file that
/// already exists inside the workspace, and refuse the command with an
/// actionable recipe — mirroring `FileMutationSupport.writeGuardBlock`.
///
/// This is intentionally NOT a full shell grammar parser. Shell syntax has
/// real ambiguity (`[[ $a > $b ]]` string comparison, `(( a >= b ))`
/// arithmetic, heredoc bodies that contain a literal `>` as plain text,
/// quoting, fd-duplication like `2>&1`) and a guard that blocks legitimate
/// commands on a false positive is worse than no guard at all. So this
/// scanner:
///   - tracks single/double quote state and skips operators found inside
///     quotes,
///   - tracks `[[ ... ]]` and `(( ... ))` nesting and skips `>` redirects
///     found inside either (bash treats a bare `>`/`>=` there as comparison,
///     not redirection),
///   - detects heredoc openers (`<<`/`<<-` plus an optional quoted or bare
///     delimiter) and skips scanning the heredoc body itself, so a `>`
///     that is just heredoc *content* is never mistaken for an operator,
///   - splits on the same command-chain boundaries as the reference
///     implementation this is ported from (`&&`, `||`, `;`, `|`, newline) —
///     done inline, in the same single pass, by tracking whether the scanner
///     is currently positioned at the start of a fresh command, rather than
///     as a separate split-then-scan phase. Verified by hand-trace that
///     plain `>` detection already worked correctly across chain boundaries
///     even before this tracking was added (the original single pass has no
///     notion of "command" and simply scans every character looking for an
///     unquoted, non-heredoc-body `>` regardless of what precedes it) — the
///     boundary tracking below exists specifically so `tee`/`dd` can be
///     recognized as a *command name in command-start position*, which
///     genuinely requires knowing where a new command begins,
///   - only ever treats `>` as a truncating write when it is not doubled
///     (`>>`, append — never blocked, by design), not `>=` (comparison),
///     and not fd-duplication/close (`>&1`, `>&-`),
///   - treats `tee FILE` as a truncating write unless `-a`/`--append` (or a
///     clustered short flag containing `a`) is present, matching `tee`'s own
///     append semantics; multiple file operands are all checked,
///   - treats `dd of=FILE` as a truncating write (dd has no equivalent
///     append flag to carve out); `if=FILE` (the input file) is left alone,
///   - fails open (does not block) whenever a target can't be statically
///     resolved to a concrete path — variable expansions (`> $FILE`,
///     `of=$FILE`), command substitutions, and process substitution
///     (`>(cmd)`) are left alone rather than risk misidentifying the target.
///
/// Known residual gaps (deliberately fail open rather than risk a false
/// block): redirect/tee/dd targets built from shell variables or command
/// substitution; targets that only become "the same file" after shell
/// expansion (e.g. via `~`, globs, or `$PWD`-relative tricks not resolvable
/// here); C-style `for ((i=0;i<n;i++))` semicolons inside `(( ))` are not
/// specially protected from being read as chain boundaries (rare, and the
/// worst case is only that `tee`/`dd` detection re-triggers mid-expression,
/// which is harmless since such expressions never actually contain `tee`/
/// `dd`). Those are left to the (weaker) approval-flow backstop.
public enum RedirectOverwriteGuard {

    /// Characters (besides whitespace) that terminate a token when reading a
    /// command name or an argument word: the start of a chain operator or a
    /// redirect, all of which must be left for the outer scan to reprocess.
    private static let tokenStopChars: Set<Character> = [";", "&", "|", ">", "<"]

    /// Inspects `command` for a truncating write (`>`/`N>`/`&>` redirect,
    /// non-appending `tee`, or `dd of=`) targeting a file that already exists
    /// inside `workspaceRoot`. Returns a human-readable error string when
    /// found, or `nil` when the command should proceed.
    public static func checkTruncatingRedirect(
        _ command: String,
        workspaceRoot: String
    ) -> String? {
        let chars = Array(command)
        var i = 0
        var inSingle = false
        var inDouble = false
        var escapeNext = false
        var testDepth = 0     // [[ ... ]]
        var arithDepth = 0    // (( ... ))
        var pendingHeredocDelims: [String] = []
        // Whether `chars[i]` is positioned at the start of a fresh command
        // (the very start of the string, or right after `;`, `&&`, `||`,
        // `|`, or a newline that isn't inside a heredoc body).
        var atCommandStart = true

        let normalizedRoot = canonicalize(workspaceRoot)

        while i < chars.count {
            let c = chars[i]

            if escapeNext {
                escapeNext = false
                i += 1
                continue
            }
            if c == "\\" && !inSingle {
                escapeNext = true
                i += 1
                continue
            }
            if c == "'" && !inDouble {
                inSingle.toggle()
                i += 1
                continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle()
                i += 1
                continue
            }
            if inSingle || inDouble {
                i += 1
                continue
            }

            if c == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                testDepth += 1
                i += 2
                continue
            }
            if c == "]", i + 1 < chars.count, chars[i + 1] == "]" {
                if testDepth > 0 { testDepth -= 1 }
                i += 2
                continue
            }
            if c == "(", i + 1 < chars.count, chars[i + 1] == "(" {
                arithDepth += 1
                i += 2
                continue
            }
            if c == ")", i + 1 < chars.count, chars[i + 1] == ")" {
                if arithDepth > 0 { arithDepth -= 1 }
                i += 2
                continue
            }

            // Heredoc opener: "<<" or "<<-", optional whitespace, then a
            // delimiter word (bare or quoted). Record the delimiter so the
            // body is skipped once we hit the newline that starts it.
            if c == "<", i + 1 < chars.count, chars[i + 1] == "<" {
                var j = i + 2
                if j < chars.count && chars[j] == "-" { j += 1 }
                while j < chars.count && (chars[j] == " " || chars[j] == "\t") { j += 1 }
                var delim = ""
                if j < chars.count, chars[j] == "'" || chars[j] == "\"" {
                    let q = chars[j]
                    j += 1
                    while j < chars.count && chars[j] != q {
                        delim.append(chars[j])
                        j += 1
                    }
                    if j < chars.count { j += 1 }
                } else {
                    while j < chars.count, !chars[j].isWhitespace {
                        delim.append(chars[j])
                        j += 1
                    }
                }
                if !delim.isEmpty {
                    pendingHeredocDelims.append(delim)
                }
                i = j
                continue
            }

            // Newline: either skip a pending heredoc body (every line until
            // one matches the delimiter exactly, trimmed) or, with none
            // pending, treat it as a command-chain boundary like the
            // reference implementation's CHAIN_OPERATORS list.
            if c == "\n" {
                if !pendingHeredocDelims.isEmpty {
                    let delim = pendingHeredocDelims.removeFirst()
                    i += 1
                    while i < chars.count {
                        var lineEnd = i
                        while lineEnd < chars.count && chars[lineEnd] != "\n" { lineEnd += 1 }
                        let line = String(chars[i..<lineEnd]).trimmingCharacters(in: .whitespaces)
                        i = lineEnd < chars.count ? lineEnd + 1 : lineEnd
                        if line == delim { break }
                    }
                } else {
                    i += 1
                }
                atCommandStart = true
                continue
            }

            // Command-chain boundaries: `&&`, `||`, `;`, `|` (single pipe).
            if c == "&", i + 1 < chars.count, chars[i + 1] == "&" {
                i += 2
                atCommandStart = true
                continue
            }
            if c == "|", i + 1 < chars.count, chars[i + 1] == "|" {
                i += 2
                atCommandStart = true
                continue
            }
            if c == "|" {
                i += 1
                atCommandStart = true
                continue
            }
            if c == ";" {
                i += 1
                atCommandStart = true
                continue
            }

            // At a fresh command position, try to read the command name and
            // recognize `tee`/`dd`. An empty read means `c` is itself one of
            // `tokenStopChars` (e.g. a bare `> file` redirect with no
            // preceding command) — leave `i` untouched and fall through to
            // the redirect handling below.
            if atCommandStart, !c.isWhitespace {
                var k = i
                let word = readToken(chars, &k, stopChars: tokenStopChars)
                if !word.isEmpty {
                    if word == "tee" || word.hasSuffix("/tee") {
                        if let blocked = scanTeeArguments(chars, from: &k, workspaceRoot: normalizedRoot) {
                            return blocked
                        }
                        i = k
                        atCommandStart = false
                        continue
                    }
                    if word == "dd" || word.hasSuffix("/dd") {
                        if let blocked = scanDDArguments(chars, from: &k, workspaceRoot: normalizedRoot) {
                            return blocked
                        }
                        i = k
                        atCommandStart = false
                        continue
                    }
                    if looksLikeAssignment(word) {
                        // `VAR=value cmd ...` — stay at command-start so the
                        // next token is re-checked as the real command name.
                        i = k
                        continue
                    }
                    i = k
                    atCommandStart = false
                    continue
                }
            }

            if c == ">" {
                if testDepth > 0 || arithDepth > 0 {
                    i += 1
                    continue
                }

                let opEnd = i + 1

                // `>>` (optionally `&>>`) — append, never blocked by design.
                if opEnd < chars.count, chars[opEnd] == ">" {
                    i = opEnd + 1
                    atCommandStart = false
                    continue
                }
                // `>=` — arithmetic/test comparison, not a redirect.
                if opEnd < chars.count, chars[opEnd] == "=" {
                    i = opEnd + 1
                    atCommandStart = false
                    continue
                }
                // `>&N` / `>&-` — fd duplication or close, not a file write.
                if opEnd < chars.count, chars[opEnd] == "&" {
                    var k = opEnd + 1
                    if k < chars.count, chars[k] == "-" {
                        i = k + 1
                        atCommandStart = false
                        continue
                    }
                    while k < chars.count, chars[k].isNumber {
                        k += 1
                    }
                    i = k
                    atCommandStart = false
                    continue
                }

                // Genuine truncating redirect: bare `>`, `N>`, or `&>`.
                var k = opEnd
                skipInlineWhitespace(chars, &k)
                guard k < chars.count else { i = opEnd; atCommandStart = false; continue }

                // `>(...)` process substitution — not a plain file target.
                if chars[k] == "(" {
                    i = k + 1
                    atCommandStart = false
                    continue
                }

                let target = readToken(chars, &k, stopChars: tokenStopChars)
                i = max(k, opEnd)
                atCommandStart = false

                guard !target.isEmpty else { continue }

                // Dynamic targets (variables, command substitution) can't be
                // statically resolved to a concrete path — fail open rather
                // than risk misjudging what file is actually touched.
                if target.contains("$") {
                    continue
                }

                let resolvedTarget = resolveTarget(target, workspaceRoot: normalizedRoot)
                guard pathIsInside(resolvedTarget, root: normalizedRoot) else {
                    continue
                }
                if FileManager.default.fileExists(atPath: resolvedTarget) {
                    return """
                        Refused: this command truncates and overwrites the existing file '\(target)' via a shell redirect ('>'), silently destroying its current content. If you need to change that file's contents, read it first, then use edit_file (path, old_text, new_text) for a targeted change, or append_file (path, content) to add to the end. If you only need to capture command output, use '>>' to append, or redirect to a new filename instead of an existing one.
                        """
                }
                continue
            }

            if !c.isWhitespace {
                atCommandStart = false
            }
            i += 1
        }

        return nil
    }

    // MARK: - tee / dd argument scanning

    /// Scans `tee`'s arguments (starting right after the command word) for
    /// flags and file operands, stopping at the next chain operator,
    /// redirect, newline, or end of string. Returns a block message if any
    /// non-append target already exists.
    private static func scanTeeArguments(
        _ chars: [Character],
        from k: inout Int,
        workspaceRoot: String
    ) -> String? {
        var appendMode = false
        var blockedTarget: String?

        while true {
            skipInlineWhitespace(chars, &k)
            guard k < chars.count else { break }
            let ch = chars[k]
            if ch == "\n" || tokenStopChars.contains(ch) { break }

            let token = readToken(chars, &k, stopChars: tokenStopChars)
            guard !token.isEmpty else { break }

            if token.hasPrefix("-") {
                if token == "--append" || (token.count > 1 && token.dropFirst().contains("a")) {
                    appendMode = true
                }
                continue
            }
            if token == "-" || token.contains("$") { continue }

            let resolved = resolveTarget(token, workspaceRoot: workspaceRoot)
            guard pathIsInside(resolved, root: workspaceRoot) else { continue }
            if blockedTarget == nil, FileManager.default.fileExists(atPath: resolved) {
                blockedTarget = token
            }
        }

        guard !appendMode, let target = blockedTarget else { return nil }
        return """
            Refused: `tee \(target)` truncates and overwrites the existing file '\(target)', silently destroying its current content. If you need to change that file's contents, read it first, then use edit_file (path, old_text, new_text) for a targeted change, or append_file (path, content) to add to the end. If you only need to capture command output, use `tee -a` to append, or write to a new filename instead of an existing one.
            """
    }

    /// Scans `dd`'s `key=value` operands for `of=FILE`, stopping at the next
    /// chain operator, redirect, newline, or end of string. `if=FILE` (the
    /// input file) is deliberately ignored. dd has no append flag to carve
    /// out, so any existing `of=` target is blocked.
    private static func scanDDArguments(
        _ chars: [Character],
        from k: inout Int,
        workspaceRoot: String
    ) -> String? {
        while true {
            skipInlineWhitespace(chars, &k)
            guard k < chars.count else { break }
            let ch = chars[k]
            if ch == "\n" || tokenStopChars.contains(ch) { break }

            let token = readToken(chars, &k, stopChars: tokenStopChars)
            guard !token.isEmpty else { break }

            guard token.hasPrefix("of=") else { continue }
            let value = String(token.dropFirst(3))
            guard !value.isEmpty, !value.contains("$") else { continue }

            let resolved = resolveTarget(value, workspaceRoot: workspaceRoot)
            guard pathIsInside(resolved, root: workspaceRoot) else { continue }
            if FileManager.default.fileExists(atPath: resolved) {
                return """
                    Refused: `dd of=\(value)` truncates and overwrites the existing file '\(value)', silently destroying its current content. If you need to change that file's contents, read it first, then use edit_file (path, old_text, new_text) for a targeted change, or append_file (path, content) to add to the end.
                    """
            }
        }
        return nil
    }

    // MARK: - Tokenizing helpers

    /// Reads one shell token starting at `chars[k]`, respecting quotes and
    /// backslash escapes, stopping at unescaped whitespace or any character
    /// in `stopChars`. Leaves `k` at the stopping character (not past it).
    private static func readToken(
        _ chars: [Character],
        _ k: inout Int,
        stopChars: Set<Character>
    ) -> String {
        var token = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        while k < chars.count {
            let c = chars[k]
            if escape {
                token.append(c); escape = false; k += 1; continue
            }
            if c == "\\" && !inSingle {
                escape = true; k += 1; continue
            }
            if c == "'" && !inDouble {
                inSingle.toggle(); k += 1; continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle(); k += 1; continue
            }
            if !inSingle && !inDouble {
                if c.isWhitespace || stopChars.contains(c) {
                    break
                }
            }
            token.append(c)
            k += 1
        }
        return token
    }

    private static func skipInlineWhitespace(_ chars: [Character], _ k: inout Int) {
        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
            k += 1
        }
    }

    /// Whether `token` looks like a leading shell variable assignment
    /// (`VAR=value`) that precedes the real command name, e.g. in
    /// `FOO=bar tee existing.txt`.
    private static func looksLikeAssignment(_ token: String) -> Bool {
        guard let eqIndex = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<eqIndex]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Path helpers

    private static func resolveTarget(_ target: String, workspaceRoot: String) -> String {
        let expanded = NSString(string: target).expandingTildeInPath
        let combined = expanded.hasPrefix("/") ? expanded : workspaceRoot + "/" + expanded
        return URL(filePath: combined).standardized.path()
    }

    private static func canonicalize(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(filePath: expanded)
            .standardized
            .resolvingSymlinksInPath()
            .path()
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        let resolvedPath = URL(filePath: path)
            .standardized
            .resolvingSymlinksInPath()
            .path()
        if resolvedPath == root { return true }
        return resolvedPath.hasPrefix(root + "/")
    }
}
