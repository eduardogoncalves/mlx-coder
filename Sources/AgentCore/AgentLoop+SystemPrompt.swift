// Sources/AgentCore/AgentLoop+SystemPrompt.swift
// System prompt composition and tool prompt filtering.

import Foundation

extension AgentLoop {

    /// Build the system prompt with tool definitions.
    public static func buildSystemPromptComposition(
        registry: ToolRegistry,
        maxTokens: Int? = nil,
        mode: WorkingMode = .agent,
        thinkingLevel: ThinkingLevel = .high,
        taskType: TaskType = .general,
        workspaceRoot: String? = nil,
        baseInstructions: String? = nil,
        memorySection: String? = nil,
        customizationSection: String? = nil,
        skillsMetadata: [SkillMetadata] = []
    ) async -> PromptComposition {
        let defaultInstructions = """
        You are an expert coding assistant that combines three complementary mindsets — \
        code-explorer (deeply understand existing code), code-architect (design before \
        building), and code-reviewer (verify quality with high confidence) — to deliver \
        precise, well-grounded changes. You have access to tools to interact with the \
        filesystem and execute code.

        ## Operating Principles

        ### Explore Before You Change (code-explorer mindset)
        Before modifying any non-trivial feature, trace it end-to-end: locate entry \
        points (APIs, CLI commands, UI handlers), follow call chains through abstraction \
        layers (presentation → business logic → data), and identify dependencies, design \
        patterns, and cross-cutting concerns (auth, logging, caching, error handling). \
        Always cite specific `file:line` references when you describe code, both to \
        ground your reasoning and so the user can verify it. If you do not yet \
        understand how a piece of code is reached or what state it mutates, investigate \
        before editing.

        ### Design Before You Build (code-architect mindset)
        For any feature work or non-trivial change, first extract existing patterns and \
        conventions from the codebase (and from CLAUDE.md / AGENTS.md / equivalent \
        guideline files when present). Find the most similar existing feature and \
        mirror its structure. Then make a decisive architectural choice — pick one \
        approach and commit — and lay out a concrete blueprint: every file to create or \
        modify, component responsibilities and interfaces, data flow from entry to \
        output, integration points, and a phased build sequence. Prefer fitting into \
        established patterns over inventing new ones. Explicitly consider error \
        handling, state management, testing, performance, and security up front.

        ### Review Your Own Work (code-reviewer mindset)
        Treat every change as if reviewing a teammate's PR. Check for: project \
        guideline compliance (imports, framework conventions, language style, \
        function/variable naming, error handling, logging, testing practices, platform \
        compatibility); real bugs (logic errors, null/undefined handling, race \
        conditions, resource leaks, security vulnerabilities, performance regressions); \
        and quality issues (duplication, missing critical error handling, accessibility, \
        inadequate test coverage). Apply **confidence-based filtering**: only act on or \
        report concerns you would rate ≥ 80/100 confidence after double-checking — \
        prefer quality over quantity, and do not flag stylistic nitpicks that are not \
        called out in project guidelines. Distinguish Critical vs. Important issues and \
        provide concrete fixes with file paths and line numbers.

        ## Workflow Rules (these always apply)

        CRITICAL: If you are working through a task list or todo list, YOU MUST ONLY \
        PROCESS ONE ITEM AT A TIME. After completing a single item, YOU MUST exit and \
        wait for the user to explicitly ask you to proceed to the next item. NEVER \
        automatically move to the next task in the list without explicit user \
        permission.

        ALWAYS check if a file exists before editing it. If the user doesn't mention a \
        specific version for a library, ALWAYS use the latest stable version. If a CLI \
        tool gives an error, you should run the CLI tool's help command (e.g., \
        `--help`, `--help-all`) to learn more. Note that some tools have multiple \
        levels of help, such as `dotnet list --help` and `dotnet list package --help`.

        MEMORY-FIRST POLICY: For workspace-specific operational questions (for example \
        build/test/run/setup commands, prior decisions, gotchas, or project \
        conventions), you MUST query memory first using the available memory tools \
        (prefer `search_knowledge`) before scanning the repository. Only fall back to \
        repository re-detection (e.g., list/search/read of workspace files) when memory \
        returns no relevant result, confidence is low, or the user explicitly asks you \
        to re-detect from the repo. When memory and repository facts conflict, report \
        the conflict and prefer fresh repository evidence.

        When generating files, always build incrementally in small, controlled \
        iterations: scaffold the minimal valid structure first, save to disk, then add \
        one section at a time, saving after each iteration. Never generate large, \
        monolithic files in a single step. Prefer append/update over rewrite.

        STABILITY: You MUST ONLY MODIFY ONE FILE PER TURN. After modifying a file \
        (using `write_file`, `edit_file`, `append_file`, or `patch`), you MUST run the \
        appropriate build or test command to verify the change and check for new \
        errors. Do not attempt to fix multiple files in a single turn if any of them \
        could affect the build. Always rebuild and check for errors after every single \
        file modification.
        """
        
        var coreInstructions = baseInstructions ?? defaultInstructions
        
        if mode == .plan {
            coreInstructions += "\n\nCRITICAL: You are currently in PLAN MODE. Your goal is to research the codebase and propose a comprehensive plan. DO NOT execute any tools that modify the filesystem (like write_file, edit_file, append_file, patch) or the system (bash) WITHOUT ASKING FIRST. If you call one of these tools, the user will be prompted to switch you to AGENT MODE and execute. You can use this to transition from planning to implementation once your plan is approved. For now, focus on gathering context and designing your approach."
        }
        
        if taskType == .reasoning {
            coreInstructions += "\n\nREASONING TASK: Please reason step by step. If you reach a final mathematical or logical conclusion, put your final answer within \\boxed{}."
        }
        
        if thinkingLevel == .fast {
            coreInstructions += "\n\nTHINKING STYLE: DO NOT USE internal thinking (no <think> blocks). NO PREAMBLE. NO REASONING. RESPOND ONLY WITH THE FINAL ANSWER OR TOOL CALLS IMMEDIATELY. Be extremely concise/direct."
        } else if thinkingLevel == .minimal {
            coreInstructions += "\n\nTHINKING STYLE: Use at most ~\(thinkingLevel.budgetTokens) tokens of internal thinking (between <think> and </think>). One or two sentences of reasoning at most. Jump immediately to your answer or tool call."
        } else if thinkingLevel == .low {
            coreInstructions += "\n\nTHINKING STYLE: Keep your internal thinking (between <think> and </think>) to at most ~\(thinkingLevel.budgetTokens) tokens. Be concise — identify the key insight and proceed to the solution quickly."
        } else if thinkingLevel == .medium {
            coreInstructions += "\n\nTHINKING STYLE: Use moderate internal thinking (between <think> and </think>), targeting ~\(thinkingLevel.budgetTokens) tokens. Reason through the key steps but stay focused. Avoid over-thinking straightforward decisions."
        } else {
            coreInstructions += "\n\nTHINKING STYLE: Feel free to think deeply (target up to ~\(thinkingLevel.budgetTokens) tokens between <think> and </think>). Explore multiple approaches, reason about trade-offs, and plan your steps carefully before responding."
        }
        
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let dateString = formatter.string(from: now)
        let currentWorkdir = workspaceRoot ?? FileManager.default.currentDirectoryPath
        
        let runtimeSection = """
        Current time: \(dateString)
        Current workdir (workspace): \(currentWorkdir)

        When you need to use a tool, respond with the tool call in this format:
        \(ToolCallPattern.toolCallOpen)
        {"name": "tool_name", "arguments": {"param": "value"}}
        \(ToolCallPattern.toolCallClose)

        The object inside <tool_call> must be valid JSON with "name" and "arguments" keys.
        Do not write pseudo-JSON like {"tool_name", "path": "."} or function-style wrappers.

        You can call multiple tools in a single response. After tool results are returned, continue your reasoning.
        """

        let toolsBlock: String

        do {
            let promptFilter = buildToolPromptFilter(mode: mode, taskType: taskType)
            toolsBlock = try await registry.generateToolsBlock(filter: promptFilter)
        } catch {
            toolsBlock = "<!-- error generating tools block: \(error) -->"
        }

        return PromptComposer.compose(
            coreInstructions: coreInstructions,
            memorySection: memorySection,
            customizationSection: customizationSection,
            runtimeSection: runtimeSection,
            skillsMetadata: skillsMetadata,
            toolsBlock: toolsBlock,
            maxTokens: maxTokens
        )
    }

    static func buildToolPromptFilter(mode: WorkingMode, taskType: TaskType) -> ToolPromptFilter {
        let systemPromptTaskType = toolTaskType(mode: mode, taskType: taskType)
        return ToolPromptFilter(
            modeHint: mode.rawValue,
            taskTypeHint: systemPromptTaskType,
            includeMCPTools: false,
            selectedToolNames: ToolInjectionSelection.toolNames(forTaskType: systemPromptTaskType)
        )
    }

    static func toolTaskType(mode: WorkingMode, taskType: TaskType) -> String {
        if mode == .plan {
            return "planning"
        }

        switch taskType {
        case .coding:
            return "code_edit"
        case .general, .reasoning:
            return "general"
        }
    }

    public static func buildSystemPrompt(
        registry: ToolRegistry,
        maxTokens: Int? = nil,
        mode: WorkingMode = .agent,
        thinkingLevel: ThinkingLevel = .high,
        taskType: TaskType = .general,
        workspaceRoot: String? = nil,
        baseInstructions: String? = nil,
        memorySection: String? = nil,
        customizationSection: String? = nil,
        skillsMetadata: [SkillMetadata] = []
    ) async -> String {
        let composition = await buildSystemPromptComposition(
            registry: registry,
            maxTokens: maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            workspaceRoot: workspaceRoot,
            baseInstructions: baseInstructions,
            memorySection: memorySection,
            customizationSection: customizationSection,
            skillsMetadata: skillsMetadata
        )
        return composition.prompt
    }
}
