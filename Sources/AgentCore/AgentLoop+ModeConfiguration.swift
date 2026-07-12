// Sources/AgentCore/AgentLoop+ModeConfiguration.swift
// Mode, thinking level, task type, and generation config management.

import Foundation
import MLX

extension AgentLoop {

    /// Toggles the sandbox mode and refreshes the system prompt.
    public func setSandbox(_ enabled: Bool) async {
        self.useSandbox = enabled
        
        // Re-register tools with the new sandbox state
        // We reuse the registration logic from MLXCoderCLI
        await registerToolsInternal()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: self.taskType,
            workspaceRoot: permissions.effectiveWorkspaceRoot,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata,
            dialect: toolCallDialect
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        // The system prompt sits at the very front of every turn's token stream, so
        // replacing it invalidates the shared prefix the persisted KV cache relies on.
        promptCache.invalidate(reason: "system prompt changed")
        
        let status = enabled ? "\u{001B}[32mEnabled\u{001B}[0m" : "\u{001B}[31mDisabled\u{001B}[0m"
        frontend.emitStatus("macOS Seatbelt Sandbox: \(status)")
    }

    /// Sets the working mode (agent/plan) and refreshes the system prompt.
    public func setMode(_ mode: WorkingMode, taskType: TaskType? = nil, silent: Bool = false) async {
        self.mode = mode
        if let taskType {
            self.taskType = taskType
            if taskType != .coding {
                skipGitOrchestrationInitialization = false
            }
        }
        syncAutopilotApprovalState()
        syncCurrentModeFromSettings()
        
        updateGenerationConfig()
        updatePendingReloadIfNeeded()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: self.taskType,
            workspaceRoot: permissions.effectiveWorkspaceRoot,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata,
            dialect: toolCallDialect
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        // The system prompt sits at the very front of every turn's token stream, so
        // replacing it invalidates the shared prefix the persisted KV cache relies on.
        promptCache.invalidate(reason: "system prompt changed")
        
        if !silent {
            frontend.emit(.modeChanged(ModeSnapshot(
                workingMode: mode.rawValue,
                thinkingLevel: thinkingLevel.rawValue,
                taskType: self.taskType.rawValue
            )))
        }
    }

    /// Sets the thinking level (low/high) and refreshes the system prompt.
    public func setThinkingLevel(_ level: ThinkingLevel) async {
        self.thinkingLevel = level
        syncCurrentModeFromSettings()
        updateGenerationConfig()
        updatePendingReloadIfNeeded()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: level,
            taskType: taskType,
            workspaceRoot: permissions.effectiveWorkspaceRoot,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata,
            dialect: toolCallDialect
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        // The system prompt sits at the very front of every turn's token stream, so
        // replacing it invalidates the shared prefix the persisted KV cache relies on.
        promptCache.invalidate(reason: "system prompt changed")
        
        frontend.emit(.modeChanged(ModeSnapshot(
            workingMode: mode.rawValue,
            thinkingLevel: level.rawValue,
            taskType: taskType.rawValue
        )))
    }

    /// Sets the task type (general/coding/reasoning) and updates generation parameters.
    public func setTaskType(_ type: TaskType) async {
        self.taskType = type
        if type != .coding {
            skipGitOrchestrationInitialization = false
        }
        syncAutopilotApprovalState()
        syncCurrentModeFromSettings()
        updateGenerationConfig()
        updatePendingReloadIfNeeded()
        
        frontend.emit(.modeChanged(ModeSnapshot(
            workingMode: mode.rawValue,
            thinkingLevel: thinkingLevel.rawValue,
            taskType: type.rawValue
        )))
    }

    /// Cycles Shift+Tab across high-level states only:
    /// coding (empty) -> plan -> autopilot -> coding.
    public func cycleMode() async -> String {
        // Keep thinking level unchanged; only rotate high-level mode semantics.
        switch (self.mode, self.taskType) {
        case (.agent, .coding):
            // coding -> plan
            self.mode = .plan
            self.taskType = .coding
        case (.plan, _):
            // plan -> autopilot (agent + allow-all-tools semantics in frontends)
            self.mode = .agent
            self.taskType = .general
        case (.agent, _):
            // autopilot/non-coding agent -> coding
            self.mode = .agent
            self.taskType = .coding
        }
        syncAutopilotApprovalState()
        syncCurrentModeFromSettings()
        
        updateGenerationConfig()
        updatePendingReloadIfNeeded()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: self.mode,
            thinkingLevel: self.thinkingLevel,
            taskType: self.taskType,
            workspaceRoot: permissions.effectiveWorkspaceRoot,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata,
            dialect: toolCallDialect
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        // The system prompt sits at the very front of every turn's token stream, so
        // replacing it invalidates the shared prefix the persisted KV cache relies on.
        promptCache.invalidate(reason: "system prompt changed")
        
        frontend.emit(.modeChanged(ModeSnapshot(
            workingMode: mode.rawValue,
            thinkingLevel: thinkingLevel.rawValue,
            taskType: taskType.rawValue
        )))
        
        return currentMode.rawValue
    }

    // MARK: - Internal Config Helpers

    func updateGenerationConfig() {
        self.currentGenerationConfig = AgentLoop.calculateGenerationConfig(
            current: currentGenerationConfig,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            mode: mode
        )
    }

    func updatePendingReloadIfNeeded() {
        // Reload only when model loading/runtime-cache parameters changed.
        // NOTE: turboQuantBits is intentionally excluded — TurboQuant creates per-generation
        // caches (not at model-load time), so changing it never requires a model reload.
        let needsReload = self.modelPath != self.loadedModelPath ||
            self.memoryLimit != self.loadedMemoryLimit ||
            self.cacheLimit != self.loadedCacheLimit ||
            self.currentGenerationConfig.kvBits != self.loadedKVBits ||
            self.currentGenerationConfig.kvGroupSize != self.loadedKVGroupSize ||
            self.currentGenerationConfig.quantizedKVStart != self.loadedQuantizedKVStart

        if needsReload {
            self.pendingReload = true
        }
    }

    func syncCurrentModeFromSettings() {
        switch mode {
        case .plan:
            currentMode = (thinkingLevel == .high || thinkingLevel == .medium) ? .planHigh : .planLow
        case .agent:
            if taskType == .coding {
                switch thinkingLevel {
                case .fast, .minimal:
                    currentMode = .agentCodingFast
                case .low, .medium:
                    currentMode = .agentCodingLow
                case .high:
                    currentMode = .agentCodingHigh
                }
            } else {
                // No dedicated General (high) label exists in ModelMode; keep non-coding labels stable.
                switch thinkingLevel {
                case .fast, .minimal:
                    currentMode = .agentGeneralFast
                case .low, .medium, .high:
                    currentMode = .agentGeneralLow
                }
            }
        }
    }

    func syncAutopilotApprovalState() {
        // In autopilot (agent + general), tool calls should proceed without prompts.
        autoApproveAllTools = (mode == .agent && taskType == .general)
    }

    static func calculateGenerationConfig(
        current: GenerationEngine.Config,
        thinkingLevel: ThinkingLevel,
        taskType: TaskType,
        mode: WorkingMode
    ) -> GenerationEngine.Config {
        // Map (thinkingLevel, taskType, mode) to the prescribed parameters
        var temp: Float = 0.6
        var topP: Float = 1.0
        var topK: Int = 0
        let minP: Float = 0.0
        var presencePenalty: Float? = nil
        var repetitionPenalty: Float? = nil
        
        // Prescribed parameter mapping:
        // 1. Thinking mode for general tasks: temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0
        // 2. Thinking mode for precise coding tasks (e.g. WebDev): temperature=0.6, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0, repetition_penalty=1.0
        // 3. Instruct (or non-thinking) mode for general tasks: temperature=0.7, top_p=0.8, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0
        // 4. Instruct (or non-thinking) mode for reasoning tasks: temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0
        
        switch thinkingLevel {
        case .fast:
            // Deterministic, no thinking
            topK = 1
            repetitionPenalty = 1.0
            temp = 0.0
            topP = 1.0
            presencePenalty = 0.0

        case .minimal:
            // Very brief thinking — close to deterministic but allows a short think block
            topK = 5
            repetitionPenalty = 1.0
            temp = 0.3
            topP = 0.85
            presencePenalty = 0.5

        case .low:
            // Instruct-style with concise thinking
            topK = 20
            repetitionPenalty = 1.0
            if mode == .plan || taskType == .reasoning {
                temp = 1.0
                topP = 0.95
                presencePenalty = 1.5
            } else {
                temp = 0.7
                topP = 0.8
                presencePenalty = 1.5
            }

        case .medium:
            // Moderate thinking — balanced depth and speed
            topK = 15
            repetitionPenalty = 1.0
            if mode == .agent || taskType == .coding {
                temp = 0.55
                topP = 0.90
                presencePenalty = 0.0
            } else {
                temp = 0.85
                topP = 0.92
                presencePenalty = 1.0
            }

        case .high:
            // Deep thinking — full reasoning budget
            topP = 0.95
            topK = 20
            repetitionPenalty = 1.0
            if mode == .agent || taskType == .coding {
                // Precise coding tasks
                temp = 0.6
                presencePenalty = 0.0
            } else {
                // General tasks (including reasoning)
                temp = 1.0
                presencePenalty = 1.5
            }
        }
        
        return GenerationEngine.Config(
            maxTokens: current.maxTokens,
            temperature: temp,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: current.repetitionContextSize,
            presencePenalty: presencePenalty,
            presenceContextSize: current.presenceContextSize,
            frequencyPenalty: current.frequencyPenalty,
            frequencyContextSize: current.frequencyContextSize,
            kvBits: current.kvBits,
            kvGroupSize: current.kvGroupSize,
            quantizedKVStart: current.quantizedKVStart,
            longContextThreshold: current.longContextThreshold,
            numDraftTokens: current.numDraftTokens
        )
    }
}
