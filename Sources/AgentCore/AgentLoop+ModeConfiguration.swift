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
            taskType: taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        let status = enabled ? "\u{001B}[32mEnabled\u{001B}[0m" : "\u{001B}[31mDisabled\u{001B}[0m"
        renderer.printStatus("macOS Seatbelt Sandbox: \(status)")
    }

    /// Sets the working mode (agent/plan) and refreshes the system prompt.
    public func setMode(_ mode: WorkingMode, silent: Bool = false) async {
        self.mode = mode
        syncCurrentModeFromSettings()
        
        updateGenerationConfig()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: thinkingLevel,
            taskType: taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        if !silent {
            let modeStr = mode == .plan ? "\u{001B}[33mPLAN\u{001B}[0m" : "\u{001B}[32mAGENT\u{001B}[0m"
            renderer.printStatus("Working Mode: \(modeStr)")
        }
    }

    /// Sets the thinking level (low/high) and refreshes the system prompt.
    public func setThinkingLevel(_ level: ThinkingLevel) async {
        self.thinkingLevel = level
        syncCurrentModeFromSettings()
        updateGenerationConfig()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: mode,
            thinkingLevel: level,
            taskType: taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        renderer.printStatus("Thinking Level: \u{001B}[32m\(level.displayName.uppercased())\u{001B}[0m")
    }

    /// Sets the task type (general/coding/reasoning) and updates generation parameters.
    public func setTaskType(_ type: TaskType) async {
        self.taskType = type
        syncCurrentModeFromSettings()
        updateGenerationConfig()
        
        let typeStr = type.rawValue.uppercased()
        renderer.printStatus("Task Type: \u{001B}[32m\(typeStr)\u{001B}[0m")
    }

    /// Cycles to the next available mode (triggered by Shift+Tab).
    public func cycleMode() async -> String {
        let allModes = ModelMode.allCases
        let currentIndex = allModes.firstIndex(of: currentMode) ?? 0
        let nextIndex = (currentIndex + 1) % allModes.count
        let nextMode = allModes[nextIndex]
        
        self.currentMode = nextMode
        
        // Map ModelMode to underlying settings
        switch nextMode {
        case .planLow:
            self.mode = .plan
            self.thinkingLevel = .low
            self.taskType = .general
        case .planHigh:
            self.mode = .plan
            self.thinkingLevel = .high
            self.taskType = .general
        case .agentGeneralFast:
            self.mode = .agent
            self.thinkingLevel = .fast
            self.taskType = .general
        case .agentGeneralLow:
            self.mode = .agent
            self.thinkingLevel = .low
            self.taskType = .general
        case .agentCodingFast:
            self.mode = .agent
            self.thinkingLevel = .fast
            self.taskType = .coding
        case .agentCodingLow:
            self.mode = .agent
            self.thinkingLevel = .low
            self.taskType = .coding
        case .agentCodingHigh:
            self.mode = .agent
            self.thinkingLevel = .high
            self.taskType = .coding
        }
        
        updateGenerationConfig()
        
        // Update system prompt in history
        let composition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: currentGenerationConfig.maxTokens,
            mode: self.mode,
            thinkingLevel: self.thinkingLevel,
            taskType: self.taskType,
            memorySection: memoryPromptSection,
            customizationSection: customizationPromptSection,
            skillsMetadata: skillsMetadata
        )
        promptSectionTokenEstimates = composition.sectionTokenEstimates
        history.updateSystemPrompt(composition.prompt)
        
        // Defer reload only if loading parameters changed
        let needsReload = self.modelPath != self.loadedModelPath ||
                          self.memoryLimit != self.loadedMemoryLimit ||
                          self.cacheLimit != self.loadedCacheLimit ||
                          self.currentGenerationConfig.kvBits != self.loadedKVBits
                          
        if needsReload {
            self.pendingReload = true
        }
        
        return nextMode.rawValue
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
            longContextThreshold: current.longContextThreshold
        )
    }
}
