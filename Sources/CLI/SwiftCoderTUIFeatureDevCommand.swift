import Foundation

/// Parser and prompt builder for the `/feature-dev` TUI slash command.
///
/// The command mirrors the Anthropic Claude Code "feature-dev" plugin
/// (https://github.com/anthropics/claude-plugins-official/tree/main/plugins/feature-dev):
/// when invoked, it injects a structured, multi-phase guided feature-development
/// prompt as a user message so the agent walks the user through Discovery →
/// Codebase Exploration → Clarifying Questions → Architecture Design →
/// Implementation → Quality Review → Summary.
///
/// Usage examples:
/// ```
/// /feature-dev
/// /feature-dev Add user authentication with OAuth
/// ```
enum TUIFeatureDevCommand {
    /// Returns true if `input` invokes the `/feature-dev` command.
    static func matches(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/feature-dev" { return true }
        return trimmed.hasPrefix("/feature-dev ") || trimmed.hasPrefix("/feature-dev\t")
    }

    /// Extracts the optional free-form arguments that follow `/feature-dev`.
    /// Returns an empty string if the command is invoked with no arguments.
    static func arguments(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/feature-dev") else { return "" }
        let after = trimmed.dropFirst("/feature-dev".count)
        return String(after).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the full prompt to send to the agent for the given arguments.
    /// The template is adapted from the official Claude Code `feature-dev`
    /// plugin and substitutes `$ARGUMENTS` with the user-supplied description
    /// (or "(none provided — ask the user)" if empty).
    static func buildPrompt(arguments: String) -> String {
        let argsValue = arguments.isEmpty
            ? "(none provided — ask the user what they want to build)"
            : arguments
        return promptTemplate.replacingOccurrences(of: "$ARGUMENTS", with: argsValue)
    }

    /// Short status line shown in the TUI transcript when the command runs.
    static func statusLine(arguments: String) -> String {
        if arguments.isEmpty {
            return "✨ /feature-dev — entering guided feature-development workflow."
        }
        return "✨ /feature-dev — guided feature-development workflow for: \(arguments)"
    }

    // MARK: - Prompt template

    /// Multi-phase guided feature-development prompt, adapted from
    /// anthropics/claude-plugins-official/plugins/feature-dev.
    static let promptTemplate: String = """
    # Feature Development

    You are helping a developer implement a new feature. Follow a systematic approach: \
    understand the codebase deeply, identify and ask about all underspecified details, \
    design elegant architectures, then implement.

    ## Core Principles

    - **Ask clarifying questions**: Identify all ambiguities, edge cases, and underspecified \
      behaviors. Ask specific, concrete questions rather than making assumptions. Wait for \
      user answers before proceeding with implementation. Ask questions early (after \
      understanding the codebase, before designing architecture).
    - **Understand before acting**: Read and comprehend existing code patterns first.
    - **Read files identified by agents/exploration**: When delegating exploration, ask for \
      lists of the most important files to read, then read those files to build detailed \
      context before proceeding.
    - **Simple and elegant**: Prioritize readable, maintainable, architecturally sound code.
    - **Track progress**: Use a todo list (e.g. the `todo` tool if available) to track all \
      phases and progress throughout.

    ---

    ## Phase 1: Discovery

    **Goal**: Understand what needs to be built.

    Initial request: $ARGUMENTS

    **Actions**:
    1. Create a todo list with all 7 phases.
    2. If the feature is unclear, ask the user for:
       - What problem are they solving?
       - What should the feature do?
       - Any constraints or requirements?
    3. Summarize your understanding and confirm with the user before moving on.

    ---

    ## Phase 2: Codebase Exploration

    **Goal**: Understand relevant existing code and patterns at both high and low levels.

    **Actions**:
    1. Explore 2–3 different aspects of the codebase in parallel where possible. For each \
       focus area:
       - Trace through the code comprehensively to understand abstractions, architecture, \
         and control flow.
       - Target a different aspect (similar features, high-level architecture, UX patterns, \
         extension points, testing approach, etc.).
       - Produce a list of 5–10 key files worth reading.

       **Example focus prompts**:
       - "Find features similar to [feature] and trace their implementation comprehensively."
       - "Map the architecture and abstractions for [feature area]."
       - "Analyze the current implementation of [existing feature/area]."
       - "Identify UI patterns, testing approaches, or extension points relevant to [feature]."

    2. Read all key files identified to build deep understanding.
    3. Present a comprehensive summary of findings and patterns discovered.

    ---

    ## Phase 3: Clarifying Questions

    **Goal**: Fill in gaps and resolve all ambiguities before designing.

    **CRITICAL**: This is one of the most important phases. DO NOT SKIP.

    **Actions**:
    1. Review the codebase findings and original feature request.
    2. Identify underspecified aspects: edge cases, error handling, integration points, \
       scope boundaries, design preferences, backward compatibility, performance needs.
    3. **Present all questions to the user in a clear, organized list.**
    4. **Wait for answers before proceeding to architecture design.**

    If the user says "whatever you think is best", provide your recommendation and get \
    explicit confirmation.

    ---

    ## Phase 4: Architecture Design

    **Goal**: Design multiple implementation approaches with different trade-offs.

    **Actions**:
    1. Draft 2–3 candidate approaches with different focuses:
       - **Minimal changes**: smallest change, maximum reuse.
       - **Clean architecture**: maintainability, elegant abstractions.
       - **Pragmatic balance**: speed + quality.
    2. Review all approaches and form an opinion on which fits best for this specific task \
       (consider: small fix vs large feature, urgency, complexity, team context).
    3. Present to the user: brief summary of each approach, trade-offs comparison, \
       **your recommendation with reasoning**, and concrete implementation differences.
    4. **Ask the user which approach they prefer.**

    ---

    ## Phase 5: Implementation

    **Goal**: Build the feature.

    **DO NOT START WITHOUT EXPLICIT USER APPROVAL.**

    **Actions**:
    1. Wait for explicit user approval of the chosen approach.
    2. Re-read all relevant files identified in previous phases.
    3. Implement following the chosen architecture.
    4. Follow codebase conventions strictly.
    5. Write clean, well-documented code.
    6. Update the todo list as you progress.

    ---

    ## Phase 6: Quality Review

    **Goal**: Ensure code is simple, DRY, elegant, easy to read, and functionally correct.

    **Actions**:
    1. Review the diff from three different angles:
       - Simplicity / DRY / elegance.
       - Bugs / functional correctness.
       - Project conventions / abstractions.
    2. Consolidate findings and identify the highest-severity issues that you recommend \
       fixing.
    3. **Present findings to the user and ask what they want to do** (fix now, fix later, \
       or proceed as-is).
    4. Address issues based on the user's decision.

    ---

    ## Phase 7: Summary

    **Goal**: Document what was accomplished.

    **Actions**:
    1. Mark all todos complete.
    2. Summarize:
       - What was built.
       - Key decisions made.
       - Files modified.
       - Suggested next steps.

    ---

    Begin with **Phase 1: Discovery** now.
    """
}
