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
        baseInstructions: String? = nil,
        memorySection: String? = nil,
        customizationSection: String? = nil,
        skillsMetadata: [SkillMetadata] = []
    ) async -> PromptComposition {
        let defaultInstructions = """
You are a helpful coding assistant. You have access to tools to interact with the filesystem and execute code.

CRITICAL EXECUTION RULES:
- If you are working through a task list or todo list, YOU MUST ONLY PROCESS ONE ITEM AT A TIME. After completing a single item, YOU MUST exit and wait for the user to explicitly ask you to proceed to the next item. NEVER automatically move to the next task in the list without explicit user permission.
- ALWAYS check if a file exists before editing it.
- If the user doesn't mention a specific version for a library, ALWAYS use the latest stable version.
- If a CLI tool gives an error, run the CLI tool's help command (e.g., `--help`, `--help-all`) to learn more.

INCREMENTAL FILE GENERATION: When generating files, always build incrementally in small, controlled iterations: scaffold the minimal valid structure first, save to disk, then add one section at a time, saving after each iteration. Never generate large, monolithic files in a single step. Prefer append/update over rewrite.

STABILITY: You MUST ONLY MODIFY ONE FILE PER TURN. After modifying a file, you MUST run the appropriate build or test command to verify the change and check for new errors. Do not attempt to fix multiple files in a single turn if any of them could affect the build. Always rebuild and check for errors after every single file modification.

TASK STRUCTURE: When planning complex tasks, structure each task using XML for clarity and precision:
<task>
  <name>Descriptive task name</name>
  <files>path/to/file1.swift, path/to/file2.swift</files>
  <action>
    Precise implementation instructions — exact function/class names to add or change,
    logic changes with clear before/after intent, any imports or dependencies needed.
  </action>
  <verify>Build/test command to confirm correctness (e.g., swift build, swift test --filter TestName)</verify>
  <done>Clear, observable success criterion</done>
</task>

ATOMIC COMMITS: After completing each task or meaningful unit of work, make an atomic git commit with a descriptive message using conventional commit format (feat:, fix:, refactor:, docs:, test:, chore:). This creates a clean, traceable history.

CONTEXT ENGINEERING: For complex projects spanning multiple sessions, maintain context files in .planning/ (create this directory if it does not exist):
- PROJECT.md — project vision and goals (loaded every session)
- REQUIREMENTS.md — scoped v1/v2 requirements
- ROADMAP.md — phases and progress
- STATE.md — current status, decisions, and blockers

GSD WORKFLOW SKILLS: If the user has installed GSD skills (visible in the skills section), they can activate them with /gsd-* commands:
- /gsd-new-project [idea]   Initialize project with planning structure
- /gsd-plan [task]           Research and create an XML execution plan
- /gsd-quick [task]          Execute an ad-hoc task with atomic commits
- /gsd-debug [issue]         Systematic debugging using the scientific method
- /gsd-review               Comprehensive code review (six pillars)
- /gsd-next                  Auto-detect state and run the next logical step
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
        
        let runtimeSection = """
        Current time: \(dateString)

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
        switch (mode, taskType) {
        case (.plan, _):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 14, maxMCPTools: 1)
        case (.agent, .coding):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 22, maxMCPTools: 2)
        case (.agent, .reasoning):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 16, maxMCPTools: 1)
        case (.agent, .general):
            return ToolPromptFilter(modeHint: mode.rawValue, taskTypeHint: taskType.rawValue, maxTools: 18, maxMCPTools: 2)
        }
    }

    public static func buildSystemPrompt(
        registry: ToolRegistry,
        maxTokens: Int? = nil,
        mode: WorkingMode = .agent,
        thinkingLevel: ThinkingLevel = .high,
        taskType: TaskType = .general,
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
            baseInstructions: baseInstructions,
            memorySection: memorySection,
            customizationSection: customizationSection,
            skillsMetadata: skillsMetadata
        )
        return composition.prompt
    }
}
