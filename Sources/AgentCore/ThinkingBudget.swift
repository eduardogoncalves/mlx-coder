// Sources/AgentCore/ThinkingBudget.swift
// Pure decision logic for enforcing `AgentLoop.ThinkingLevel.budgetTokens` at
// runtime.
//
// Historically `budgetTokens` was rendered into the system prompt (see
// `AgentLoop+SystemPrompt.swift`) as a *request* to the model — small models
// routinely ignore it and keep deliberating well past the intended budget.
// The arithmetic here decides, given how many thinking tokens have streamed
// so far this turn, whether the harness should force the `<think>` block
// closed. It is factored out as a free function (rather than living inline
// in the per-token loop) so it can be unit-tested without a loaded model —
// see `AgentLoop+Generation.swift` for where it's invoked from the live
// token stream, and `AgentLoop.swift` for how a breach is threaded back out
// to the outer tool loop (mirrors the existing `finishReason == "length"`
// handling there).
//
// Local-only: this has no bearing on `AgentLoop+OpenRouterGeneration.swift`.
// The remote path never tracks `isThinking` (it hardcodes
// `startedThinking: false` and pipes text deltas straight through), so there
// is nothing here to enforce against — a remote model's thinking tokens
// (if any) are entirely opaque to us.

import Foundation

extension AgentLoop {

    /// How much slack (in tokens) to allow past `budgetTokens` before forcing
    /// the thinking block closed.
    ///
    /// A hard cut at exactly `budgetTokens` routinely lands mid-clause or
    /// mid-word — the model has no warning that it's about to be cut off, so
    /// the truncated think text (and the synthetic close tag appended right
    /// after it) reads as mangled. Give it enough room to wrap up the
    /// sentence it's currently on: 20% of the budget, with a floor of 24
    /// tokens (roughly one short clause) so small budgets — including the
    /// budget-0 edge case handled by `shouldStopThinking` — still get a little
    /// runway instead of being cut on literally the first token over.
    static func thinkingBudgetTolerance(budgetTokens: Int) -> Int {
        max(24, budgetTokens / 5)
    }

    /// Whether the harness should force the current `<think>` block closed
    /// right now.
    ///
    /// - Parameters:
    ///   - thinkingTokensSoFar: number of generated tokens counted while the
    ///     model was inside the think block for THIS turn (see the per-token
    ///     loop in `generateResponse()`). Counted in tokens, not characters —
    ///     tokens are what the model's own budget is denominated in.
    ///   - budgetTokens: the effective `ThinkingLevel.budgetTokens` for this
    ///     turn (the caller may substitute `ThinkingLevel.fast.budgetTokens`
    ///     — i.e. 0 — when thinking was meant to be suppressed entirely this
    ///     turn; see `forceThinkingOffNextTurn` in `AgentLoop.swift`).
    ///   - isThinking: `StreamParser.isThinking` — the authoritative "we are
    ///     still inside an open think block" signal. If the model has
    ///     already closed the block on its own, there is nothing to enforce.
    /// - Returns: `true` once `thinkingTokensSoFar` exceeds
    ///   `budgetTokens + thinkingBudgetTolerance(budgetTokens)`.
    ///
    /// Semantics for a zero budget (`ThinkingLevel.fast`, or a forced
    /// suppression): `.fast` disables thinking at the prompt level
    /// (`enableThinking = false`), so in the overwhelmingly common case
    /// `StreamParser` never opens a think block, `isThinking` stays false,
    /// and this function never has anything to do. If a model ignores that
    /// and starts a think block anyway, a 0 budget is NOT treated as "abort
    /// on the very first thinking token" — it still gets the tolerance floor
    /// (`thinkingBudgetTolerance(0) == 24`), so the intervention fires
    /// quickly but not so abruptly that it fires before the model could
    /// possibly have reacted.
    static func shouldStopThinking(
        thinkingTokensSoFar: Int,
        budgetTokens: Int,
        isThinking: Bool
    ) -> Bool {
        guard isThinking else { return false }
        let limit = budgetTokens + thinkingBudgetTolerance(budgetTokens)
        return thinkingTokensSoFar > limit
    }
}
