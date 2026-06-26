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

    @Option(name: .shortAndLong, help: "The prompt to send to the agent (omit when using --voice)")
    var prompt: String?

    @Flag(name: .long, help: "Record voice input via Speech Recognition and use the transcription as the prompt")
    var voice: Bool = false

    @Option(name: .long, help: "Optional path to export markdown session history after run")
    var saveHistory: String?

    @Option(name: .long, help: "Optional path to export JSON session history after run")
    var saveHistoryJSON: String?

    mutating func run() async throws {
        guard !args.testAbsorber.isTestInvocation else { return }
        let renderer = StreamRenderer(verbose: args.verbose)
        let interactiveInput = InteractiveInput()
        let frontend = LegacyTerminalFrontend(renderer: renderer, interactiveInput: interactiveInput)
        defer {
            Task {
                await DotnetLSPService.shared.shutdown()
            }
        }

        // Resolve effective prompt — transcribe via voice if requested.
        let effectivePrompt: String
        if voice {
            #if canImport(Speech)
            renderer.printStatus("🎤 Starting voice input…")
            do {
                let voiceLocale = args.resolvedVoiceLocale
                let transcription = try await VoiceInput.transcribe(
                    silenceTimeout: args.voiceSilenceTimeout,
                    locale: voiceLocale
                )
                renderer.printStatus("🎤 \"\(transcription)\"")
                effectivePrompt = transcription
            } catch {
                renderer.printError("Voice input failed: \(error.localizedDescription)")
                return
            }
            #else
            renderer.printError("--voice requires macOS with the Speech framework.")
            return
            #endif
        } else if let p = prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectivePrompt = p
        } else {
            renderer.printError("Provide a prompt with --prompt or use --voice to dictate one.")
            return
        }
        // Detect chip and configure memory
        let chipInfo = ChipDetector.detect()
        let budget = MemoryGuard.budgetFor(chip: chipInfo)
        MemoryGuard.configure(budget: budget)

        let selectedModel = args.model
        let selectedBackend = InferenceBackend(modelPath: selectedModel)
        if let providerID = selectedBackend.providerID, !Credentials.isConfigured(providerID) {
            renderer.printError("Online model selected but \(providerID) is not configured. Run /login \(providerID) <api-key> or set \(Credentials.envVarName(for: providerID)).")
            return
        }

        if selectedBackend.isLocal && !localModelExists(selectedModel) && !looksLikeHubModelID(selectedModel) {
            renderer.printStatus("No local model found at \(selectedModel).")
            renderer.printStatus("Using Apple Foundation fallback for this single prompt.")
            if await runAppleFoundationSinglePromptFallback(prompt: effectivePrompt, renderer: renderer) {
                return
            }
            renderer.printError("Apple Foundation model is unavailable. Use --model with a local model path or a Hugging Face model ID.")
            renderer.printStatus("Suggested IDs: mlx-community/Qwen3.5-9B-MLX-4bit, Tesslate/OmniCoder-9B")
            return
        }

        // Load local model only for local backends; online backends stream over HTTP.
        let modelContainer: ModelContainer?
        if selectedBackend.isOnline {
            renderer.printStatus("Using online model \(selectedModel)")
            modelContainer = nil
        } else {
            renderer.printStatus("Loading model...")
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
        }

        let draftModelPath = args.resolvedDraftModelPath(for: selectedModel)
        let draftModel: AgentLoop.DraftModelHandle?
        if let draftModelPath {
            if selectedBackend.isOnline {
                renderer.printStatus("Ignoring --draft-model for online backends.")
                draftModel = nil
            } else if let modelContainer,
                Qwen3DFlashDraftOverride.isDFlashDraft(draftModelPath: draftModelPath) {
                // EAGLE-style DFlash draft: build a custom runtime instead of loading
                // a standard token-level draft model.
                do {
                    let runtime = try await Qwen3DFlashDraftOverride.buildRuntime(
                        draftModelPath: draftModelPath,
                        mainModelPath: selectedModel,
                        mainModelContainer: modelContainer,
                        renderer: renderer
                    )
                    draftModel = AgentLoop.DraftModelHandle(dflash: runtime)
                } catch is CancellationError {
                    return
                } catch {
                    if args.isDraftModelExplicitlyProvided {
                        renderer.printError("Failed to build DFlash draft: \(error.localizedDescription)")
                        return
                    }
                    renderer.printStatus("DFlash draft unavailable (\(error.localizedDescription)). Continuing without speculative decoding.")
                    draftModel = nil
                }
            } else {
                let effectiveDraftPath: String?
                do {
                    if let modelContainer {
                        effectiveDraftPath = try await Qwen35MTPDraftOverride.prepareIfNeeded(
                            draftModelPath: draftModelPath,
                            mainModelPath: selectedModel,
                            mainModelContainer: modelContainer,
                            renderer: renderer
                        )
                    } else {
                        effectiveDraftPath = draftModelPath
                    }
                } catch {
                    if args.isDraftModelExplicitlyProvided {
                        renderer.printError("Failed to prepare draft model override: \(error.localizedDescription)")
                        return
                    }
                    renderer.printStatus("Draft override unavailable (\(error.localizedDescription)). Continuing without speculative decoding.")
                    effectiveDraftPath = nil
                }

                if let effectiveDraftPath {
                    renderer.printStatus("Loading draft model from \(effectiveDraftPath)...")
                    do {
                        let draftContainer = try await loadModelWithCancellation(
                            from: effectiveDraftPath,
                            memoryLimit: budget.totalBytes,
                            cacheLimit: budget.cacheBytes,
                            renderer: renderer
                        )
                        draftModel = await draftContainer.perform { context in
                            AgentLoop.DraftModelHandle(model: context.model)
                        }
                        renderer.printStatus("Draft model loaded successfully")
                    } catch is CancellationError {
                        return
                    } catch {
                        if args.isDraftModelExplicitlyProvided {
                            renderer.printError("Failed to load draft model: \(error.localizedDescription)")
                            return
                        }
                        renderer.printStatus("Draft model unavailable (\(error.localizedDescription)). Continuing without speculative decoding.")
                        draftModel = nil
                    }
                } else {
                    draftModel = nil
                }
            }
        } else {
            draftModel = nil
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
            turboQuantBits: args.turboQuantBits,
            numDraftTokens: args.numDraftTokens
        )
        
        // Set up tools
        let workspacePath = NSString(string: args.workspace).expandingTildeInPath
        let absWorkspace = workspacePath.hasPrefix("/") ? workspacePath : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let runtimeConfig = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)
        // Auto-load project env vars from <workspace>/.mlx-coder.env so child
        // processes (bash tool, LSP servers, …) inherit them every session.
        let workspaceEnv = WorkspaceEnvironment.applyToCurrentProcess(workspaceRoot: absWorkspace)
        if !workspaceEnv.isEmpty {
            renderer.printStatus("Loaded \(workspaceEnv.count) workspace env var(s) from \(WorkspaceEnvironment.fileName)")
        }
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
        let skillsRegistry = SkillsRegistry(workspaceRoot: absWorkspace)
        await registerAllTools(
            registry: registry,
            permissions: permissions,
            modelContainer: modelContainer,
            modelPath: selectedModel,
            useSandbox: effectiveSandbox,
            config: config,
            renderer: renderer,
            frontend: frontend,
            mcpConfigs: mergedMCPConfigs(
                runtimeConfigs: runtimeMCPConfigs,
                cliConfig: makeMCPServerConfig(from: args)
            ),
            skillsRegistry: skillsRegistry
        )

        let skillMetadata = await skillsRegistry.listMetadata()
        let hooks = HookPipeline()
        await hooks.register(AuditHook(logger: auditLogger))
        let promptComposition = await AgentLoop.buildSystemPromptComposition(
            registry: registry,
            maxTokens: args.maxTokens,
            mode: .plan,
            thinkingLevel: .low,
            taskType: .general,
            workspaceRoot: absWorkspace,
            skillsMetadata: skillMetadata,
            dialect: ToolCallDialect.detect(modelPath: selectedModel)
        )

        let agentLoop = AgentLoop(
            modelContainer: modelContainer,
            registry: registry,
            permissions: permissions,
            generationConfig: config,
            frontend: frontend,
            verbose: args.verbose,
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
            cacheLimit: budget.cacheBytes,
            draftModel: draftModel
        )

        let parsedPrompt = ImageAttachmentParser.parse(prompt: effectivePrompt)
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
