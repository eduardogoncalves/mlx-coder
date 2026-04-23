// Sources/MLXCoder/RunCommand.swift
// Single-prompt, non-interactive subcommand.

import ArgumentParser
import Foundation
import MLXLMCommon

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a single prompt and exit"
    )

    @OptionGroup var args: ModelArguments

    @Option(name: .shortAndLong, help: "The prompt to send to the agent")
    var prompt: String

    @Option(name: .long, help: "Optional path to export markdown session history after run")
    var saveHistory: String?

    @Option(name: .long, help: "Optional path to export JSON session history after run")
    var saveHistoryJSON: String?

    mutating func run() async throws {
        guard !args.testAbsorber.isTestInvocation else { return }
        let renderer = StreamRenderer(verbose: args.verbose)
        defer {
            Task {
                await DotnetLSPService.shared.shutdown()
            }
        }

        // Detect chip and configure memory
        let chipInfo = ChipDetector.detect()
        let budget = MemoryGuard.budgetFor(chip: chipInfo)
        MemoryGuard.configure(budget: budget)

        let selectedModel = args.model
        if !localModelExists(selectedModel) && !looksLikeHubModelID(selectedModel) {
            renderer.printStatus("No local model found at \(selectedModel).")
            renderer.printStatus("Using Apple Foundation fallback for this single prompt.")
            if await runAppleFoundationSinglePromptFallback(prompt: prompt, renderer: renderer) {
                return
            }
            renderer.printError("Apple Foundation model is unavailable. Use --model with a local model path or a Hugging Face model ID.")
            renderer.printStatus("Suggested IDs: mlx-community/Qwen3.5-9B-MLX-4bit, Tesslate/OmniCoder-9B")
            return
        }

        // Load model
        renderer.printStatus("Loading model...")
        let modelContainer: ModelContainer
        do {
            modelContainer = try await loadModelWithCancellation(
                from: selectedModel,
                memoryLimit: budget.totalBytes,
                cacheLimit: budget.cacheBytes,
                renderer: renderer
            )
        } catch is CancellationError {
            return
        } catch {
            renderer.printError("Failed to load model: \(error.localizedDescription)")
            return
        }

        // Run single prompt setup
        let profile = ParameterProfile.forChip(chipInfo)
        let config = GenerationEngine.Config(
            maxTokens: args.maxTokens,
            temperature: args.temperature,
            topP: args.topP,
            kvBits: args.kvBits ?? profile.kvBits,
            kvGroupSize: args.kvGroupSize ?? profile.kvGroupSize,
            quantizedKVStart: args.quantizedKVStart ?? profile.quantizedKVStart,
            longContextThreshold: profile.longContextThreshold,
            turboQuantBits: args.turboQuantBits
        )
        
        // Set up tools
        let workspacePath = NSString(string: args.workspace).expandingTildeInPath
        let absWorkspace = workspacePath.hasPrefix("/") ? workspacePath : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        let effectiveApprovalMode = resolvedApprovalMode(from: args.approvalMode, runtimeConfig: runtimeConfig)
        let effectivePolicyFile = args.policyFile ?? runtimeConfig.defaultPolicyFile
        let effectiveAuditLogPath = args.auditLogPath ?? runtimeConfig.defaultAuditLogPath
        let effectiveSandbox = resolvedSandbox(cliSandbox: args.sandbox, runtimeConfig: runtimeConfig)
        let effectiveDryRun = resolvedDryRun(cliDryRun: args.dryRun, runtimeConfig: runtimeConfig)
        let ignorePatterns = loadIgnorePatterns(workspaceRoot: absWorkspace)

        let permissions = PermissionEngine(
            workspaceRoot: absWorkspace,
            approvalMode: effectiveApprovalMode,
            policy: loadPermissionPolicy(explicitPath: effectivePolicyFile, workspaceRoot: absWorkspace, renderer: renderer),
            ignoredPathPatterns: ignorePatterns
        )
        let auditLogger = ToolAuditLogger(
            logFilePath: effectiveAuditLogPath,
            workspaceRoot: absWorkspace,
            approvalMode: permissions.approvalMode.rawValue
        )

        let registry = ToolRegistry()
        let runtimeMCPConfigs = runtimeMCPServerConfigs(
            from: runtimeConfig,
            includeOverride: args.mcpInclude,
            excludeOverride: args.mcpExclude
        )
        await registerAllTools(
            registry: registry,
            permissions: permissions,
            modelContainer: modelContainer,
            modelPath: selectedModel,
            useSandbox: effectiveSandbox,
            config: config,
            renderer: renderer,
            mcpConfigs: mergedMCPConfigs(
                runtimeConfigs: runtimeMCPConfigs,
                cliConfig: makeMCPServerConfig(from: args)
            )
        )

        let skillsRegistry = SkillsRegistry(workspaceRoot: absWorkspace)
        let skillMetadata = await skillsRegistry.listMetadata()
        let hooks = HookPipeline()
        await hooks.register(AuditHook(logger: auditLogger))
        let promptComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: args.maxTokens,
            mode: .plan,
            thinkingLevel: .low,
            taskType: .general,
            skillsMetadata: skillMetadata
        )

        let agentLoop = AgentLoop(
            modelContainer: modelContainer,
            registry: registry,
            permissions: permissions,
            generationConfig: config,
            renderer: renderer,
            systemPrompt: promptComposition.prompt,
            modelPath: selectedModel,
            workspace: absWorkspace,
            useSandbox: effectiveSandbox,
            useShadowContextForToolResults: args.shadowContext,
            auditLogger: auditLogger,
            dryRun: effectiveDryRun,
            hooks: hooks,
            skillsMetadata: skillMetadata,
            promptSectionTokenEstimates: promptComposition.sectionTokenEstimates,
            memoryLimit: budget.totalBytes,
            cacheLimit: budget.cacheBytes
        )

        let parsedPrompt = ImageAttachmentParser.parse(prompt: prompt)
        if !parsedPrompt.imageURLs.isEmpty {
            renderer.printStatus("Attaching \(parsedPrompt.imageURLs.count) image(s): \(parsedPrompt.imageURLs.map(\.lastPathComponent).joined(separator: ", "))")
        }
        renderer.printStatus("Generation active. Press Esc or Ctrl+C to cancel.")
        let runTask = Task {
            try await agentLoop.processUserMessage(parsedPrompt.cleanedPrompt, images: parsedPrompt.imageURLs)
        }
        await CancelController.shared.setTask(runTask, forceExitOnEscape: true)
        do {
            try await runTask.value
            await CancelController.shared.setTask(nil)
        } catch is CancellationError {
            await CancelController.shared.setTask(nil)
            renderer.printError("Generation cancelled by user.")
            return
        } catch {
            await CancelController.shared.setTask(nil)
            throw error
        }

        if let output = saveHistory?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            _ = try await agentLoop.exportHistory(to: output)
        }

        if let outputJSON = saveHistoryJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !outputJSON.isEmpty {
            _ = try await agentLoop.exportHistoryJSON(to: outputJSON)
        }
    }
}
