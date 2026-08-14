// Sources/AgentCore/ToolResultCondensation.swift
// Policy/config for summarizing large tool outputs before storing in main history

import Foundation

public struct ToolResultCondensationConfig: Sendable {
    public let largeResultTokenThreshold: Int
    public let charsPerTokenEstimate: Int
    public let summaryTargetTokens: Int
    public let maxSummaryChars: Int
    public let fallbackRawChars: Int
    public let eligibleTools: Set<String>

    public init(
        largeResultTokenThreshold: Int = 1000,
        charsPerTokenEstimate: Int = 4,
        summaryTargetTokens: Int = 300,
        maxSummaryChars: Int = 1200,
        fallbackRawChars: Int = 4000,
        eligibleTools: Set<String> = ["web_fetch", "read_file", "read_many", "bash", "web_search"]
    ) {
        self.largeResultTokenThreshold = max(1, largeResultTokenThreshold)
        self.charsPerTokenEstimate = max(1, charsPerTokenEstimate)
        self.summaryTargetTokens = max(64, summaryTargetTokens)
        self.maxSummaryChars = max(256, maxSummaryChars)
        self.fallbackRawChars = max(512, fallbackRawChars)
        self.eligibleTools = eligibleTools
    }
}

enum ToolResultCondensationPolicy {
    // read_skill is exempt: skill instructions must reach the model verbatim,
    // and the tool already bounds its own output via pagination.
    private static let neverCondenseTools: Set<String> = ["todo", "list_dir", "dir_list", "read_skill"]

    // MARK: - Budget-aware trimming (live remaining-context-window awareness)
    //
    // Everything above/below this section keys off a STATIC char-count
    // threshold (`ToolResultCondensationConfig.largeResultTokenThreshold`) with
    // no knowledge of how much of the context window is actually left. The
    // functions in this section are a port of little-coder's `read-guard`
    // (`shouldTrimRead`), generalized from "read file" to "any oversized tool
    // result about to enter main history," and are layered ON TOP of the
    // existing static gate as an independent OR-condition — see
    // `AgentLoop+ToolCondensation.swift: makeToolResponseForHistory` for how
    // the two are combined. They never loosen existing behavior, only add a
    // second reason to trim when the static threshold alone would have let a
    // result through unchanged but live headroom can't actually afford it.

    /// Tools whose mechanical (non-LLM) fallback trim is safe to force purely
    /// because of tight remaining context budget. This is the single canonical
    /// definition — `AgentLoop+ToolCondensation.swift` reads it rather than
    /// keeping its own copy — precisely so the budget-aware gate below can
    /// never drift out of sync with "which tools are LLM-summarization-safe."
    /// Re-entrant MLX model invocations during condensation corrupt KV-cache
    /// state (see that file's doc comment on `nonLLMCondensationTools`'
    /// original use site), so `isBudgetAwareEligible`/`shouldForceBudgetTrim`
    /// below only ever return `true` for tools in this set — by construction,
    /// the budget-aware path can never route a result into LLM summarization.
    static let nonLLMCondensationTools: Set<String> = ["read_file", "read_many", "web_search", "bash", "task"]

    /// Of `nonLLMCondensationTools`, the subset whose mechanical fallback uses
    /// the head-N-lines "read guard" message (structure-only slice + explicit
    /// "don't re-read in full" steering) instead of the generic bounded-raw
    /// fallback. `read_file`/`read_many` return line-oriented file content
    /// where a head slice is meaningful; `bash`/`task` output is deliberately
    /// kept from the TAIL instead (exit status/errors are at the end — see
    /// `boundedFallbackRawMessage`), and `web_search` keeps the existing
    /// head-char-based fallback. Preserving that asymmetry is a hard
    /// requirement, not an oversight.
    static let readGuardTools: Set<String> = ["read_file", "read_many"]

    /// Number of leading lines kept for the head-N "read guard" message.
    /// Mirrors little-coder's `read-guard` `HEAD_LINES` constant.
    static let readGuardHeadLines = 30

    /// Fraction of the effective context window assumed already consumed when
    /// live usage is unmeasurable (no tokenizer/model loaded — e.g. a
    /// remote-only OpenRouter session has no local tokenizer at all). Mirrors
    /// little-coder's `read-guard` `FALLBACK_FRACTION`: rather than never
    /// trimming when usage is unknown, conservatively assume the window is
    /// already half spoken for.
    static let budgetFallbackFraction: Double = 0.5

    /// A remaining-budget snapshot: live token usage against the effective
    /// context window. `currentTokens` is `nil` exactly when live usage
    /// couldn't be measured (no tokenizer/model loaded) — see
    /// `budgetFallbackFraction` for that case. `windowTokens` is meant to be
    /// `currentGenerationConfig.longContextThreshold` — the same "effective
    /// window" stand-in `ContextWatchdog` uses for its percent-of-window
    /// compaction trigger (see that file's doc comment: it's the only number
    /// in this codebase already playing the "context window" role). This
    /// deliberately reuses that number rather than inventing a second,
    /// competing notion of the window.
    struct BudgetContext: Sendable, Equatable {
        let currentTokens: Int?
        let windowTokens: Int

        init(currentTokens: Int?, windowTokens: Int) {
            self.currentTokens = currentTokens
            self.windowTokens = windowTokens
        }
    }

    /// Tokens of headroom left before `budget.windowTokens` is exhausted.
    /// `Int.max` when there is no effective window at all (`windowTokens <= 0`)
    /// — "unbounded," matching the other guard clauses in this section that
    /// treat a nonpositive window as "budget awareness doesn't apply here."
    static func remainingBudgetTokens(_ budget: BudgetContext) -> Int {
        guard budget.windowTokens > 0 else { return Int.max }
        if let currentTokens = budget.currentTokens {
            return max(0, budget.windowTokens - currentTokens)
        }
        return max(0, Int(Double(budget.windowTokens) * (1 - budgetFallbackFraction)))
    }

    /// Direct port of little-coder's `read-guard` `shouldTrimRead`, generalized
    /// from "read file" to "any oversized tool result being written to
    /// history": given the raw result's line count and a head-line floor below
    /// which trimming wouldn't shrink anything meaningful, decide whether the
    /// live remaining budget requires trimming this specific result before it
    /// enters main history.
    ///
    /// - `lineCount <= headLines`: never trim — mirrors the reference's first
    ///   guard (a head slice of the whole thing isn't smaller than the whole
    ///   thing).
    /// - `budget.currentTokens` known: trims once
    ///   `currentTokens + estimatedResultTokens` would exceed the window
    ///   (reference's `RESERVE = 0` — no extra safety margin beyond the window
    ///   itself).
    /// - `budget.currentTokens` unknown (no tokenizer/model loaded): trims once
    ///   the result *alone* would exceed `budgetFallbackFraction` of the window
    ///   — the reference's `FALLBACK_FRACTION` path.
    static func shouldTrimForBudget(
        lineCount: Int,
        headLines: Int,
        estimatedResultTokens: Int,
        budget: BudgetContext
    ) -> Bool {
        guard budget.windowTokens > 0 else { return false }
        guard lineCount > headLines else { return false }

        if let currentTokens = budget.currentTokens {
            return currentTokens + estimatedResultTokens > budget.windowTokens
        }

        return Double(estimatedResultTokens) > Double(budget.windowTokens) * budgetFallbackFraction
    }

    /// Whether `toolName` is even a candidate for the budget-aware forced-trim
    /// path — i.e. it passes the same exemption/eligibility gates as
    /// `shouldCondense` (never-condense tools, caller-configured eligibility)
    /// AND is mechanically trimmable without an LLM call. Mirrors
    /// `shouldCondense`'s exemption checks exactly so a tool exempted from the
    /// static-threshold path (e.g. `todo`, `list_dir`, `read_skill`) can never
    /// be pulled into condensation through this side door.
    static func isBudgetAwareEligible(toolName: String, config: ToolResultCondensationConfig) -> Bool {
        guard !neverCondenseTools.contains(toolName) else { return false }
        guard config.eligibleTools.contains(toolName) else { return false }
        return nonLLMCondensationTools.contains(toolName)
    }

    /// Whether the mechanical fallback trim should fire purely because of tight
    /// remaining context budget, for a result the *static* char-count threshold
    /// (`shouldCondense`) would otherwise let through unchanged. Only ever
    /// returns `true` for `nonLLMCondensationTools` (via `isBudgetAwareEligible`)
    /// — by construction this can never route a result into LLM summarization.
    static func shouldForceBudgetTrim(
        toolName: String,
        result: ToolResult,
        config: ToolResultCondensationConfig,
        budget: BudgetContext
    ) -> Bool {
        guard !result.isError else { return false }
        guard isBudgetAwareEligible(toolName: toolName, config: config) else { return false }

        let raw = joinedToolOutput(result: result)
        let estimatedTokens = estimatedTokenCount(for: raw, charsPerToken: config.charsPerTokenEstimate)
        let headLines = readGuardTools.contains(toolName) ? readGuardHeadLines : 0
        let lineCount = raw.isEmpty ? 0 : raw.components(separatedBy: "\n").count

        return shouldTrimForBudget(
            lineCount: lineCount,
            headLines: headLines,
            estimatedResultTokens: estimatedTokens,
            budget: budget
        )
    }

    /// Budget-aware cap on how many raw characters the mechanical fallback
    /// keeps: never more than `staticMaxChars` (so ample-budget behavior is
    /// unchanged from today — this only ever tightens, never loosens), but
    /// scaled down to the live remaining budget (converted to chars via
    /// `charsPerToken`) once headroom is actually scarce. Floors at 512 chars
    /// so the fallback never collapses to something useless.
    static func effectiveFallbackRawChars(
        staticMaxChars: Int,
        charsPerToken: Int,
        budget: BudgetContext
    ) -> Int {
        let remainingTokens = remainingBudgetTokens(budget)
        guard remainingTokens != Int.max else { return staticMaxChars }
        let remainingChars = remainingTokens * max(1, charsPerToken)
        return max(512, min(staticMaxChars, remainingChars))
    }

    /// Ports little-coder's `read-guard` trimmed-result message shape for
    /// `read_file`/`read_many`: keep only the first `headLines` lines (enough
    /// to see structure — imports, top-level declarations), then explicitly
    /// steer the model away from ever requesting the file in full again.
    static func budgetTrimmedReadMessage(
        toolName: String,
        raw: String,
        headLines: Int,
        estimatedTokens: Int,
        reason: String = "reading it in full would exceed the remaining context window"
    ) -> String {
        let lines = raw.isEmpty ? [] : raw.components(separatedBy: "\n")
        let totalLines = lines.count
        guard totalLines > headLines else {
            // Caller's budget check established trimming is warranted, but
            // there's no shorter head to offer here — return unchanged rather
            // than fabricate a slice that isn't actually smaller.
            return raw
        }
        let kept = lines.prefix(headLines).joined(separator: "\n")
        return """
        [Context budget guard] This result has \(totalLines) lines (~\(estimatedTokens) tokens estimated) — \(reason), so only the first \(headLines) lines are shown below.
        Tool: \(toolName)
        - Use these lines to understand the file's structure (imports, top-level declarations, overall shape).
        - Narrow down with grep / code_search / glob to find the specific section you need, then call \(toolName) again with a specific start_line/end_line range.
        - Do NOT re-read this file in full — it will be trimmed again.

        \(kept)
        """
    }

    static func joinedToolOutput(result: ToolResult) -> String {
        var text = result.content
        if let marker = result.truncationMarker {
            text += "\n\(marker)"
        }
        return text
    }

    static func estimatedTokenCount(for text: String, charsPerToken: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let divisor = max(1, charsPerToken)
        return max(1, text.count / divisor)
    }

    static func shouldCondense(toolName: String, result: ToolResult, config: ToolResultCondensationConfig) -> Bool {
        guard !result.isError else { return false }
        guard !neverCondenseTools.contains(toolName) else { return false }
        guard config.eligibleTools.contains(toolName) else { return false }

        let raw = joinedToolOutput(result: result)

        // web_fetch may already return query-focused extraction text.
        // Re-condensing it can drop critical details and trigger redundant refetch loops.
        if toolName == "web_fetch", isAlreadyQueryExtractedWebFetch(raw) {
            return false
        }

        // Web tools always go through condensation — their raw content (HTML / search
        // results) can be huge and must never reach the main context unfiltered.
        let webToolNames: Set<String> = ["web_fetch", "web_search"]
        if webToolNames.contains(toolName) {
            return true
        }

        let estimatedTokens = estimatedTokenCount(for: raw, charsPerToken: config.charsPerTokenEstimate)
        guard estimatedTokens > config.largeResultTokenThreshold else { return false }

        // Skip compact structured payloads (already concise and low-risk for context bloat).
        if isLikelyCompactStructuredPayload(raw) {
            return false
        }

        return true
    }

    static func isLikelyCompactStructuredPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2000 else { return false }

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return true
        }

        return false
    }

    static func isAlreadyQueryExtractedWebFetch(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return lower.hasPrefix("extracted information for query '")
            || lower.hasPrefix("extracted information for query \"")
    }

    static func sanitizeSummary(_ text: String, maxChars: Int) -> String {
        let stripped = text
            .replacingOccurrences(of: ToolCallPattern.eosToken, with: "")
            .replacingOccurrences(of: ToolCallPattern.imEnd, with: "")
            .replacingOccurrences(of: ToolCallPattern.imStart, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if stripped.count <= maxChars {
            return stripped
        }

        return String(stripped.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatCondensedToolMessage(toolName: String, summary: String) -> String {
        """
        [Tool output summarized for context efficiency]
        Tool: \(toolName)
        Summary:
        \(summary)
        """
    }

    static func boundedFallbackRawMessage(toolName: String, raw: String, maxChars: Int) -> String {
        guard raw.count > maxChars else { return raw }

        // For shell tools keep the TAIL: exit status, errors, and final results always
        // appear at the end of command output.  Use a generous cap so build errors are
        // never silently dropped.
        let shellTools: Set<String> = ["bash", "task"]
        if shellTools.contains(toolName) {
            let bashMaxChars = max(maxChars, 8_000)
            if raw.count <= bashMaxChars {
                return raw
            }
            let kept = String(raw.suffix(bashMaxChars))
            let omitted = raw.count - bashMaxChars
            return """
            [Tool output truncated — showing last \(bashMaxChars) chars]
            Tool: \(toolName)
            [... \(omitted) characters omitted ...]
            \(kept)
            """
        }

        let kept = String(raw.prefix(maxChars))
        let omitted = raw.count - maxChars
        return """
        [Tool output could not be summarized; bounded raw fallback]
        Tool: \(toolName)
        \(kept)
        [... \(omitted) characters omitted ...]
        """
    }

    static func instructionTemplate(for toolName: String) -> String {
        switch toolName {
        case "read_file", "read_many":
            return """
            - Prefer a short structural snapshot first (what file(s), relevant sections).
            - Call out exact symbol names and line ranges when present.
            - Keep only code facts that directly affect the goal.
            """
        case "bash", "task":
            return """
            - Prioritize final status (success/failure), key diagnostics, and actionable next step.
            - Keep exact command output snippets only when they are error-defining.
            - Omit progress spam, repeated lines, and non-actionable noise.
            """
        case "grep", "code_search", "glob", "list_dir":
            return """
            - Keep only matches that are likely relevant to the goal.
            - Include concrete file paths and symbols, not full result dumps.
            - Report counts briefly when useful.
            """
        case "web_fetch", "web_search":
            return """
            - Extract verifiable facts only; preserve exact values and quoted phrases.
            - Mention uncertainty or missing data explicitly.
            - Avoid narrative summary beyond source-supported facts.
            """
        default:
            return """
            - Keep only high-signal facts needed for the next reasoning step.
            - Preserve exact identifiers, numbers, and error text.
            - Remove repetition and non-essential detail.
            """
        }
    }
}
