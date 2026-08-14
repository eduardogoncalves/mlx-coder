// Sources/CLI/SwiftCoderTUISession.swift
// Minimal SwiftCoderTUI-driven REPL for mlx-coder. Wired by ChatCommand
// when the user passes `--ui tui`. The legacy REPL stays the default.
//
// Scope of this initial pass:
//   • Full-screen TUI shell (welcome, footer, scroll area)
//   • Slash-commands `/clear`, `/quit`, `/help` handled locally
//   • All other input goes to AgentLoop.processUserMessage, with output
//     streamed via SwiftCoderTUIFrontend
//   • Approval modal driven by Renderer.requestApproval (best-effort —
//     AgentLoop's native raw-mode approval still owns the actual decision
//     until Phase 5 fully replaces it)
//
// Out of scope here (deferred): autocomplete, voice, multi-line input,
// model/mode picker overlays, history persistence.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import MLX
import SwiftCoderTUI

struct TUIShellCommandParseResult: Equatable {
    let command: String?
    let suppressHistory: Bool
}

/// Which deterministic workflow command to reach for, shown in each
/// command's own usage error (no description given) so the choice is
/// explained right where it matters, not just buried in /help. `/feature`
/// and `/discovery` run the identical research→plan→execute→review
/// pipeline — the only difference is whether it pauses before the mutating
/// stages — so the real decision is "how settled is this request", not
/// which pipeline is "better". Mirrored in ChatCommand.swift for the
/// non-TUI REPL (same three commands, same reasoning, duplicated rather
/// than shared since the two front-ends don't share a commands module).
private let workflowCommandUsageHints: [String: String] = [
    "/discovery": "Requirements still unclear or open-ended? Use this — it researches, plans, then pauses for your OK before touching any files.",
    "/feature": "Already know exactly what to build? Use this — runs research→plan→execute→review straight through, no pause. Reach for /discovery instead if you're not yet sure what the change should look like.",
    "/fix": "For a known, reproducible bug — the bug report itself defines the scope, so this skips straight to diagnose→fix→verify (no separate planning stage).",
]

enum TUIShellCommandParser {
    static func parse(_ input: String) -> TUIShellCommandParseResult {
        if input == "!!" {
            return .init(command: "", suppressHistory: true)
        }
        if input.hasPrefix("!!"), input.count > 2 {
            return .init(
                command: String(input.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                suppressHistory: true
            )
        }
        if input.hasPrefix("!"), input.count > 1 {
            return .init(
                command: String(input.dropFirst()).trimmingCharacters(in: .whitespaces),
                suppressHistory: false
            )
        }
        return .init(command: nil, suppressHistory: false)
    }
}

private enum ModelFilterMode {
    case all
    case freeOnly
}

/// Identifies a session the user can resume after quitting. Returned by
/// `runSwiftCoderTUISession` so the caller can print the resume hint.
public struct SessionResumeInfo: Sendable {
    public let id: String
    public let title: String
}

@MainActor
public func runSwiftCoderTUISession(
    agentLoop: AgentLoop,
    frontend: SwiftCoderTUIFrontend,
    skillMetadata: [SkillMetadata],
    hooks: HookPipeline,
    initialSandboxEnabled: Bool,
    resumeSessionId: String? = nil
) async -> SessionResumeInfo? {
    let processTerminal = ProcessTerminal()
    processTerminal.setupRawMode(title: frontend.appConfig.appName)
    defer { processTerminal.restoreMode() }

    let renderer = frontend.renderer

    let caffeinateManager = CaffeinateManager()
    // Tracks whether the user explicitly pinned caffeinate on/off via
    // `/caffeinate`. When pinned, the orchestrator's automatic per-turn
    // keep-awake (below) leaves the manual setting alone; otherwise it turns
    // caffeinate on for the duration of each turn and back off once it ends.
    var caffeinateManuallyPinned = false
    func beginOrchestratorCaffeinate() async {
        guard !caffeinateManuallyPinned else { return }
        await caffeinateManager.enable(mode: .on)
    }
    func endOrchestratorCaffeinate() {
        guard !caffeinateManuallyPinned else { return }
        Task { await caffeinateManager.disable() }
    }

    let dynamicCommandNames: Set<String> = ["/model", "/effort", "/caffeinate", "/memory", "/login", "/logout", "/resume"]
    let staticItems = frontend.appConfig.commands
        .filter { !dynamicCommandNames.contains($0.name) }
        .map { command -> AutocompleteItem in
            let commandBody = String(command.name.dropFirst()) // drop leading "/"
            // Some entries document a trailing argument placeholder for the palette
            // (e.g. "/terminal <msg>"). Accepting the item inserts `value` verbatim
            // (see AutocompleteProvider.completionString), so a placeholder left in
            // `value` would land as literal text in the input buffer — and because
            // it then contains an embedded space, the accept-result no longer looks
            // like a just-completed slash command, so Enter submits it immediately
            // instead of leaving the cursor ready for a real message. Strip it from
            // `value` (keeping it in `label` for display) so accepting inserts just
            // "/terminal " and waits for the user to type the actual message.
            let value: String
            if let lastSpace = commandBody.lastIndex(of: " ") {
                let trailingToken = commandBody[commandBody.index(after: lastSpace)...]
                value = trailingToken.hasPrefix("<") ? String(commandBody[..<lastSpace]) : commandBody
            } else {
                value = commandBody
            }
            return AutocompleteItem(value: value, label: command.name, description: command.description)
        }
    // Session-local model list. Starts from appConfig (built at startup) but is
    // mutated when a remote provider's catalog is refreshed so the user sees
    // fresh entries without relaunching. AppConfig.models is `let`, so we keep
    // our own copy here and pass it into handleModelCommand explicitly.
    var modelFilterMode: ModelFilterMode = .all
    var sessionModels = frontend.appConfig.models
    func makeAutocompleteProvider() -> CombinedAutocompleteProvider {
        CombinedAutocompleteProvider(
            commands: [
                TUIModelSlashCommand(models: sessionModels),
                TUIEffortSlashCommand(),
                CaffeinateSlashCommand(),
                TUIMemorySlashCommand(),
                TUILoginSlashCommand(),
                TUILogoutSlashCommand(),
                TUIResumeSlashCommand(),
            ],
            staticCommands: staticItems
        )
    }
    await renderer.setAutocompleteProvider(makeAutocompleteProvider())

    await renderer.setupScreen()
    await renderer.setSandboxEnabled(initialSandboxEnabled)
    let initialWorkingMode = await agentLoop.mode
    let initialTaskType = await agentLoop.taskType
    let initialThinkingLevel = await agentLoop.thinkingLevel.rawValue
    if let initialModeIndex = modeIndex(
        workingMode: initialWorkingMode,
        taskType: initialTaskType,
        thinkingLevel: initialThinkingLevel,
        appConfig: frontend.appConfig
    ) {
        await renderer.setCurrentModeIndex(initialModeIndex)
    }
    let initialStatusMode = statusModeLabel(workingMode: initialWorkingMode, taskType: initialTaskType)
    await renderer.setAutopilot(initialStatusMode == "autopilot")
    await renderer.setStatusModeLabel(initialStatusMode)
    await renderer.showWelcome()
    await renderer.renderFooter()

    let inputHistory = InputHistory()
    var activeStreamTask: Task<Void, Never>? = nil
    var sigwinchSource: DispatchSourceSignal? = nil
    var pendingResizeTask: Task<Void, Never>? = nil
    var lastUserPrompt: String?
    let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardized.path
    var shouldQuit = false
    var pendingTypedChunk = ""
    var pendingTypedFlushTask: Task<Void, Never>? = nil

    // Persistence key for this session's on-disk transcript. Starts from the
    // AgentLoop's own id; `/resume` re-points it at the restored session so
    // continued turns append to the same file, and `/clear` mints a fresh id so
    // the cleared conversation becomes a new (still-resumable) session without
    // overwriting the old one.
    var currentSessionId = await agentLoop.sessionId
    // Auto-save the current transcript to ~/.mlx-coder/sessions/<id>.json. Cheap
    // (a few KB) and called after every completed turn plus on quit, so a crash
    // never loses more than the in-flight turn.
    func saveCurrentSession() async {
        let messages = await agentLoop.persistableConversation
        let model = await agentLoop.activeModelPath
        let slotSnapshot = await agentLoop.remoteSlotSnapshot
        SessionStore.save(
            id: currentSessionId,
            cwd: workspaceRoot,
            model: model,
            messages: messages,
            remoteSlotId: slotSnapshot?.idSlot,
            remoteSlotFilename: slotSnapshot?.filename
        )
    }

    // Load a saved session into the live AgentLoop and replay its transcript to
    // the scroll area. Returns false (with an error line) when the id is unknown.
    func restoreSession(id: String) async -> Bool {
        let session: PersistedSession
        do {
            session = try SessionStore.load(id: id)
        } catch {
            await renderer.printScrollLine("\(DesignSystem.brightRed)✗ No saved session found for id \(id)\(DesignSystem.reset)")
            return false
        }
        await agentLoop.restoreConversation(session.messages)
        currentSessionId = session.id
        await agentLoop.rebindKVCachePersistenceId(session.id)
        if let slotId = session.remoteSlotId, let filename = session.remoteSlotFilename {
            await agentLoop.primeRemoteSlotRestore(sessionModelPath: session.model, idSlot: slotId, filename: filename)
        }
        // Replay the human/assistant/tool turns so the user sees the context they
        // are resuming. Automated steering messages stay out of the transcript.
        for message in session.messages {
            switch message.role {
            case .user where message.origin == .human:
                await renderer.printScrollLine(SessionEntry(role: .user, content: message.content).render())
            case .assistant where !message.content.isEmpty:
                await renderer.printScrollLine(SessionEntry(role: .assistant, content: message.content).render())
            case .tool:
                await renderer.printScrollLine(SessionEntry(role: .toolOutput, content: message.content).render())
            default:
                break
            }
        }
        lastUserPrompt = await agentLoop.history.latestUserMessage
        await renderer.printScrollLine("\(DesignSystem.dim)↩ Resumed session \(session.id)\(DesignSystem.reset)")
        await renderer.renderFooter()
        return true
    }

    // Deny-with-suggestion entry state. When the user picks "No, suggest
    // changes" (or presses Esc) on an approval menu, the session switches the
    // input box into a one-shot suggestion prompt instead of resolving the
    // denial immediately. The previous input-box content is stashed and
    // restored once the suggestion is submitted or cancelled.
    var approvalSuggestionMode = false
    var approvalStashedInput = ""

    // Clarifying-questions "Other" free-text entry state (ask_user_question
    // tool). Mirrors approvalSuggestionMode/approvalStashedInput above: while
    // the user is typing a custom answer, the input box is reused for text
    // entry and its previous content is stashed/restored around it.
    var clarifyingStashedInput = ""

    // /login wizard state. While non-.idle, free-text input is captured by the
    // wizard and never forwarded to AgentLoop.
    var loginWizardStep: LoginWizardStep = .idle

    // Memory edit mode — when non-nil, all keystrokes are captured by the
    // inline editor and never forwarded to autocomplete or AgentLoop paths.
    // Mirrors the loginWizardStep pattern; all access is @MainActor-isolated.
    var pendingEditEntry: KnowledgeEntry? = nil
    var memoryFlowTask: Task<Void, Never>? = nil

    // Voice input session state. `voiceProvider` is the same instance wired
    // into `AppConfig.voiceInputProvider` in `ChatCommand`, captured here so
    // the keystroke loop can call `requestStop()` (e.g. on Enter) while the
    // recording task is awaiting `renderer.triggerVoiceInput()` in the
    // background. `voiceTask` tracks the in-flight recording task; while it
    // is non-nil and not finished, Enter stops the recording instead of
    // submitting the prompt.
    let voiceProvider = frontend.appConfig.voiceInputProvider as? MLXCoderVoiceInputProvider
    var voiceTask: Task<Void, Never>? = nil
    var voiceSpinnerTask: Task<Void, Never>? = nil

    signal(SIGWINCH, SIG_IGN)
    let resizeSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    resizeSource.setEventHandler {
        pendingResizeTask?.cancel()
        pendingResizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            let old = await renderer.updateSize()
            await renderer.handleResize(oldRows: old.oldRows, oldCols: old.oldCols)
        }
    }
    resizeSource.resume()
    sigwinchSource = resizeSource

    // Restore a session requested on the command line (--resume / --continue)
    // before accepting any input.
    if let resumeSessionId {
        _ = await restoreSession(id: resumeSessionId)
    }

    mainLoop: for await key in InputHandler.keystrokes() {
        // If the approval was resolved externally (e.g. the generation task
        // was cancelled) while the suggestion prompt was open, restore the
        // normal input state before processing the key.
        if approvalSuggestionMode && !frontend.hasPendingApproval {
            approvalSuggestionMode = false
            await renderer.setStatusNotice(nil)
            await renderer.setInputBuffer(approvalStashedInput)
            approvalStashedInput = ""
            await renderer.renderFooter()
        }

        // Approval intercept — when the agent has paused for a tool decision.
        // Must run before typed-character buffering so numeric choices (1-4)
        // are handled immediately instead of being swallowed into input.
        if frontend.hasPendingApproval {
            pendingTypedFlushTask?.cancel()
            pendingTypedFlushTask = nil
            pendingTypedChunk.removeAll(keepingCapacity: true)

            // Suggestion entry: the user picked "No, suggest changes" and is
            // typing feedback into the input box.
            if approvalSuggestionMode {
                switch key {
                case .character(let ch):
                    await renderer.appendChar(ch)
                    await renderer.renderFooter()
                case .backspace, .delete:
                    await renderer.deleteChar()
                    await renderer.renderFooter()
                case .arrowLeft:
                    await renderer.moveCursorLeft()
                    await renderer.renderFooter()
                case .arrowRight:
                    await renderer.moveCursorRight()
                    await renderer.renderFooter()
                case .paste(let pasted):
                    await renderer.insertText(pasted)
                    await renderer.renderFooter()
                case .enter:
                    let suggestion = await renderer.getInputBuffer()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    approvalSuggestionMode = false
                    await renderer.setStatusNotice(nil)
                    await renderer.setInputBuffer(approvalStashedInput)
                    approvalStashedInput = ""
                    await renderer.renderFooter()
                    frontend.resolveApproval(.deny(suggestion: suggestion.isEmpty ? nil : suggestion))
                case .escape:
                    approvalSuggestionMode = false
                    await renderer.setStatusNotice(nil)
                    await renderer.setInputBuffer(approvalStashedInput)
                    approvalStashedInput = ""
                    await renderer.renderFooter()
                    frontend.resolveApproval(.deny(suggestion: nil))
                default:
                    break
                }
                continue
            }

            let isPlanMode = await renderer.getApprovalIsPlanMode()
            let optionCount = await renderer.getApprovalOptionCount()
            // The deny option is always last ("No, suggest changes (esc)" /
            // "Deny"). Picking it opens the suggestion prompt instead of
            // resolving immediately.
            let denyIndex = optionCount - 1
            var startSuggestionEntry = false

            switch key {
            case .character(let ch):
                if let digit = Int(String(ch)), (1...optionCount).contains(digit) {
                    if digit - 1 == denyIndex {
                        startSuggestionEntry = true
                    } else {
                        let decision = isPlanMode
                            ? planModeDecisionForOption(digit - 1)
                            : decisionForOption(digit - 1)
                        frontend.resolveApproval(decision)
                    }
                }
            case .enter:
                let sel = await renderer.getApprovalSelection()
                if sel == nil || sel == denyIndex {
                    startSuggestionEntry = true
                } else {
                    let decision = isPlanMode
                        ? planModeDecisionForOption(sel)
                        : decisionForOption(sel)
                    frontend.resolveApproval(decision)
                }
            case .escape:
                startSuggestionEntry = true
            case .arrowUp:
                await renderer.moveApprovalSelection(offset: -1)
            case .arrowDown:
                await renderer.moveApprovalSelection(offset: 1)
            default:
                break
            }

            if startSuggestionEntry {
                approvalSuggestionMode = true
                approvalStashedInput = await renderer.getInputBuffer()
                await renderer.setInputBuffer("")
                await renderer.clearApproval()
                await renderer.setStatusNotice(
                    "Denying tool call — type suggested changes and press Enter (empty = no comment, Esc = deny silently)"
                )
                await renderer.renderFooter()
            }
            continue
        }

        // Option-select intercept — when the agent is waiting for the user to
        // pick one of several options (e.g., git branch setup menu).
        if frontend.hasPendingOptionSelect {
            pendingTypedFlushTask?.cancel()
            pendingTypedFlushTask = nil
            pendingTypedChunk.removeAll(keepingCapacity: true)
            let optionCount = await renderer.getOptionSelectOptionCount()
            let escSelectsLast = await renderer.getOptionSelectEscSelectsLastOption()
            switch key {
            case .character(let ch):
                if let digit = Int(String(ch)), (1...optionCount).contains(digit) {
                    frontend.resolveOptionSelect(digit - 1)
                }
            case .enter:
                let sel = await renderer.getOptionSelectSelection()
                frontend.resolveOptionSelect(sel)
            case .escape:
                if escSelectsLast {
                    frontend.resolveOptionSelect(optionCount - 1)
                } else {
                    frontend.resolveOptionSelect(nil)
                }
            case .arrowUp:
                await renderer.moveOptionSelectSelection(offset: -1)
            case .arrowDown:
                await renderer.moveOptionSelectSelection(offset: 1)
            default:
                break
            }
            continue
        }

        // Clarifying-questions intercept — the model called `ask_user_question`
        // and is waiting on one or more multiple-choice answers.
        if frontend.hasPendingClarifyingQuestions {
            pendingTypedFlushTask?.cancel()
            pendingTypedFlushTask = nil
            pendingTypedChunk.removeAll(keepingCapacity: true)

            // Escape always cancels the whole batch, even mid "Other" text
            // entry — matches approval/optionSelect's Esc-cancels convention.
            if case .escape = key {
                if await renderer.getClarifyingIsEnteringOtherText() {
                    await renderer.setInputBuffer(clarifyingStashedInput)
                    clarifyingStashedInput = ""
                }
                frontend.resolveClarifyingQuestions(nil)
                await renderer.renderFooter()
                continue
            }

            if await renderer.getClarifyingIsEnteringOtherText() {
                switch key {
                case .character(let ch):
                    await renderer.appendChar(ch)
                    await renderer.renderFooter()
                case .backspace, .delete:
                    await renderer.deleteChar()
                    await renderer.renderFooter()
                case .arrowLeft:
                    await renderer.moveCursorLeft()
                    await renderer.renderFooter()
                case .arrowRight:
                    await renderer.moveCursorRight()
                    await renderer.renderFooter()
                case .paste(let pasted):
                    await renderer.insertText(pasted)
                    await renderer.renderFooter()
                case .enter:
                    let text = await renderer.getInputBuffer().trimmingCharacters(in: .whitespacesAndNewlines)
                    await renderer.setInputBuffer(clarifyingStashedInput)
                    clarifyingStashedInput = ""
                    let completed = await renderer.finishClarifyingOtherText(text)
                    if completed {
                        let answers = await renderer.getClarifyingAnswers().map { ClarifyingAnswer(selectedLabels: $0) }
                        frontend.resolveClarifyingQuestions(answers)
                    }
                    await renderer.renderFooter()
                default:
                    break
                }
                continue
            }

            let optionCount = await renderer.getClarifyingOptionCount()
            let isMultiSelect = await renderer.getClarifyingIsMultiSelect()
            let isOtherRowSelected = await renderer.getClarifyingIsOtherRowSelected()

            switch key {
            case .character(" "):
                await renderer.toggleClarifyingCursorOption()
            case .character(let ch):
                if let digit = Int(String(ch)), (1...optionCount).contains(digit) {
                    if isMultiSelect {
                        await renderer.toggleClarifyingOption(at: digit - 1)
                    } else {
                        let completed = await renderer.selectClarifyingDigitAndSubmit(digit)
                        if completed {
                            let answers = await renderer.getClarifyingAnswers().map { ClarifyingAnswer(selectedLabels: $0) }
                            frontend.resolveClarifyingQuestions(answers)
                        }
                        await renderer.renderFooter()
                    }
                }
            case .enter:
                if isOtherRowSelected {
                    clarifyingStashedInput = await renderer.getInputBuffer()
                    await renderer.setInputBuffer("")
                    await renderer.beginClarifyingOtherEntry()
                } else {
                    let completed = await renderer.submitClarifyingCurrentQuestion()
                    if completed {
                        let answers = await renderer.getClarifyingAnswers().map { ClarifyingAnswer(selectedLabels: $0) }
                        frontend.resolveClarifyingQuestions(answers)
                    }
                }
            case .arrowUp:
                await renderer.moveClarifyingCursor(offset: -1)
            case .arrowDown:
                await renderer.moveClarifyingCursor(offset: 1)
            default:
                break
            }
            await renderer.renderFooter()
            continue
        }

        // Login wizard — when active, all input is captured by the wizard and
        // never forwarded to the autocomplete or AgentLoop paths.
        if loginWizardStep != .idle {
            switch key {
            case .character(let ch):
                await renderer.appendChar(ch)
                await renderer.renderFooter()
            case .backspace, .delete:
                await renderer.deleteChar()
                await renderer.renderFooter()
            case .arrowLeft:
                await renderer.moveCursorLeft()
                await renderer.renderFooter()
            case .arrowRight:
                await renderer.moveCursorRight()
                await renderer.renderFooter()
            case .paste(let pasted):
                await renderer.insertText(pasted)
                await renderer.renderFooter()
            case .enter:
                let value = await renderer.getInputBuffer()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await renderer.setInputBuffer("")
                let (nextStep, addedID) = await advanceLoginWizard(
                    step: loginWizardStep, value: value, renderer: renderer
                )
                loginWizardStep = nextStep
                await renderer.renderFooter()
                if let id = addedID {
                    await refreshRemoteCatalog(providerID: id, renderer: renderer)
                    sessionModels = rebuildSessionModels(
                        base: frontend.appConfig.models, filterMode: modelFilterMode
                    )
                    await renderer.setAutocompleteProvider(makeAutocompleteProvider())
                }
            case .escape, .ctrlC:
                loginWizardStep = .idle
                await renderer.setStatusNotice(nil)
                await renderer.setInputBuffer("")
                await renderer.renderFooter()
                await renderer.printScrollLine("  Cancelled.")
            default:
                break
            }
            continue
        }

        // Memory edit mode — intercept all keystrokes while user edits an entry.
        // Mirrors the loginWizardStep pattern: all input captured here, never
        // forwarded to history navigation, model-cycle, or AgentLoop paths.
        if pendingEditEntry != nil {
            switch key {
            case .character(let ch):
                await renderer.appendChar(ch)
                await renderer.renderFooter()
            case .backspace, .delete:
                await renderer.deleteChar()
                await renderer.renderFooter()
            case .arrowLeft:
                await renderer.moveCursorLeft()
                await renderer.renderFooter()
            case .arrowRight:
                await renderer.moveCursorRight()
                await renderer.renderFooter()
            case .paste(let pasted):
                await renderer.insertText(pasted)
                await renderer.renderFooter()
            case .enter:
                let newContent = (await renderer.submitInput() ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let editEntry = pendingEditEntry!
                pendingEditEntry = nil
                await renderer.setStatusNotice(nil)
                await renderer.renderFooter()
                guard !newContent.isEmpty else {
                    await renderer.printScrollLine("  Edit cancelled (empty content).")
                    break
                }
                let store = KnowledgeStore.shared
                do {
                    try await store.initialize()
                    try await store.update(id: editEntry.id, content: newContent)
                    await renderer.printScrollLine("  \(DesignSystem.dim)✓ Entry updated.\(DesignSystem.reset)")
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Update failed: \(error)\(DesignSystem.reset)")
                }
                await renderer.renderFooter()
            case .escape, .ctrlC:
                pendingEditEntry = nil
                await renderer.setStatusNotice(nil)
                await renderer.setInputBuffer("")
                await renderer.renderFooter()
                await renderer.printScrollLine("  Edit cancelled.")
            default:
                break
            }
            continue
        }

        if case .character(let ch) = key {
            if ch == " " {
                pendingTypedFlushTask?.cancel()
                await flushPendingTypedChunk(&pendingTypedChunk, renderer: renderer)
                if await renderer.isAutocompleteActive() {
                    await renderer.acceptAutocomplete()
                    await renderer.renderFooter()
                    continue
                }
            }
            pendingTypedChunk.append(ch)
            if ch == "/" || ch == "@" || pendingTypedChunk.count >= 32 || ch == "\n" || ch == "\r" {
                pendingTypedFlushTask?.cancel()
                await flushPendingTypedChunk(&pendingTypedChunk, renderer: renderer)
            } else {
                pendingTypedFlushTask?.cancel()
                pendingTypedFlushTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 12_000_000)
                    guard !Task.isCancelled else { return }
                    await flushPendingTypedChunk(&pendingTypedChunk, renderer: renderer)
                    pendingTypedFlushTask = nil
                }
            }
            continue
        } else {
            pendingTypedFlushTask?.cancel()
            if case .tab = key {
                await flushPendingTypedChunk(&pendingTypedChunk, renderer: renderer, render: false)
            } else {
                await flushPendingTypedChunk(&pendingTypedChunk, renderer: renderer)
            }
        }

        switch key {
        case .character:
            break

        case .backspace, .delete:
            await renderer.deleteChar()
            await renderer.renderFooter()

        case .arrowLeft:
            await renderer.moveCursorLeft()
            await renderer.renderFooter()

        case .arrowRight:
            await renderer.moveCursorRight()
            await renderer.renderFooter()

        case .arrowUp:
            if await renderer.isAutocompleteActive() {
                await renderer.moveAutocompleteSelection(offset: -1)
                await renderer.renderFooter()
            } else if let prev = inputHistory.previous() {
                await renderer.setInputBuffer(prev)
                await normalizeInputSoftWrap(renderer: renderer)
                await renderer.renderFooter()
            }

        case .arrowDown:
            if await renderer.isAutocompleteActive() {
                await renderer.moveAutocompleteSelection(offset: 1)
                await renderer.renderFooter()
            } else if let next = inputHistory.next() {
                await renderer.setInputBuffer(next)
                await normalizeInputSoftWrap(renderer: renderer)
                await renderer.renderFooter()
            } else {
                await renderer.setInputBuffer("")
                await renderer.renderFooter()
            }

        case .ctrlC:
            if let provider = voiceProvider, voiceTask != nil {
                provider.requestStop()
            }
            activeStreamTask?.cancel()
            await frontend.abortGeneration()

        case .escape:
            if let provider = voiceProvider, voiceTask != nil {
                provider.requestStop()
            } else if await renderer.isAutocompleteActive() {
                await renderer.clearAutocomplete()
                await renderer.renderFooter()
            } else if activeStreamTask != nil {
                // activeStreamTask, not renderer.getIsGenerating(): a turn stays
                // in flight through tool execution (e.g. a slow bash call), but
                // isGenerating already clears once the model finishes emitting
                // text. Gating on isGenerating meant Esc silently did nothing
                // while a tool was still running — the one key meant to bail out
                // of exactly that "looks stuck" state.
                activeStreamTask?.cancel()
                await frontend.abortGeneration()
            }

        case .ctrlL:
            let old = await renderer.updateSize()
            await renderer.handleResize(oldRows: old.oldRows, oldCols: old.oldCols)

        case .tab:
            if await renderer.isAutocompleteActive() {
                let result = await renderer.acceptAutocomplete()
                await renderer.renderFooter()
                if result == .directory || result == .slashCommand {
                    Task {
                        await renderer.updateAutocomplete()
                        await renderer.renderFooter()
                    }
                }
            } else {
                await renderer.openCommandPalette()
                await renderer.renderFooter()
            }

        case .shiftTab:
            _ = await agentLoop.cycleMode()
            await renderer.renderFooter()

        case .ctrlP:
            await cycleModelShortcut(
                models: sessionModels,
                defaultIndex: frontend.appConfig.defaultModelIndex,
                agentLoop: agentLoop,
                renderer: renderer,
                reverse: false,
                deferReload: true
            )

        case .shiftCtrlP:
            await cycleModelShortcut(
                models: sessionModels,
                defaultIndex: frontend.appConfig.defaultModelIndex,
                agentLoop: agentLoop,
                renderer: renderer,
                reverse: true,
                deferReload: true
            )

        case .paste(let pasted):
            await renderer.insertText(pasted)
            await normalizeInputSoftWrap(renderer: renderer)
            await renderer.renderFooter()

        case .ctrlV:
            // Toggle voice recording. The renderer's `triggerVoiceInput()`
            // owns the "Listening…" thinking-text + input-buffer prefill, but
            // it does not animate the footer on its own (the spinner ticker
            // in `SwiftCoderTUIFrontend` only runs for agent generation
            // events), so we run our own 100 ms ticker while recording is
            // active. The voice call runs in a sibling task so the keystroke
            // loop stays responsive — Enter / Ctrl+V can then call
            // `voiceProvider.requestStop()` to end recording immediately
            // instead of waiting for the silence timeout.
            guard let provider = voiceProvider else {
                await renderer.printScrollLine(
                    "\(DesignSystem.brightRed)✗ Voice input is not configured in this session.\(DesignSystem.reset)"
                )
                await renderer.renderFooter()
                break
            }
            if voiceTask != nil {
                provider.requestStop()
                break
            }
            // Show an ephemeral "🎤 Listening…" notice in the footer area
            // via the upstream `setStatusNotice` API (added in swift-coder-tui
            // commit eb0c5cd). Unlike `setThinking`/`setGenerating`, this
            // renders as a plain caller-styled line with no spinner glyph
            // and no "(esc · Ns)" suffix, and it disappears when cleared
            // instead of persisting in the scroll transcript.
            await renderer.setStatusNotice(
                "\(DesignSystem.brightYellow)🎤 Listening… press Enter to finish or ESC to cancel\(DesignSystem.reset)"
            )
            voiceSpinnerTask?.cancel()
            voiceSpinnerTask = nil
            voiceTask = Task { @MainActor in
                let transcription: String
                do {
                    transcription = try await provider.transcribe()
                } catch {
                    await renderer.setStatusNotice(nil)
                    await renderer.printScrollLine(
                        "\(DesignSystem.brightRed)🎤 Voice input failed: \(error.localizedDescription)\(DesignSystem.reset)"
                    )
                    await renderer.renderFooter()
                    voiceTask = nil
                    return
                }
                await renderer.setStatusNotice(nil)
                if !transcription.isEmpty {
                    await renderer.setInputBuffer(transcription)
                    await renderer.moveCursorToEnd()
                }
                await normalizeInputSoftWrap(renderer: renderer)
                await renderer.renderFooter()
                voiceTask = nil
            }

        case .altEnter, .shiftEnter:
            await renderer.insertText("\n")
            await normalizeInputSoftWrap(renderer: renderer)
            await renderer.renderFooter()

        case .enter:
            // While a voice recording is active, Enter stops the mic instead
            // of submitting. The transcription lands in the input buffer so
            // the user can review/edit it, then press Enter again to send.
            if let provider = voiceProvider, voiceTask != nil {
                provider.requestStop()
                continue
            }
            if await renderer.convertBackslashToNewline() {
                await renderer.renderFooter()
                continue
            }
            // Accept any pending ghost/autocomplete suggestion before submitting,
            // so "/q" + Enter expands to "/quit" and executes it.
            if await renderer.isAutocompleteActive() {
                let result = await renderer.acceptAutocomplete()
                await renderer.renderFooter()
                if result == .directory || result == .slashCommand {
                    Task {
                        await renderer.updateAutocomplete()
                        await renderer.renderFooter()
                    }
                    continue
                }
                // .plain result: auto-submit if the completed input is a slash command
                // (e.g. "/model local" selected from palette → execute immediately).
                // Non-command completions (e.g. @file in a message body) still require
                // an explicit second Enter so the user can continue composing.
                let completedInput = await renderer.getInputBuffer()
                if !completedInput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                    continue
                }
                // Fall through to the submit path below.
            }
            let prompt = (await renderer.submitInput()) ?? ""
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandInput = normalizedCommandInput(from: trimmed)
            let commandInputLower = commandInput.lowercased()
            if trimmed.isEmpty {
                await renderer.renderFooter()
                continue
            }
            inputHistory.add(trimmed)
            inputHistory.resetCursor()

            if commandInput == "/quit" || commandInput == "exit" || commandInput == "quit" {
                shouldQuit = true
                break mainLoop
            }
            if commandInput == "/clear" {
                await renderer.clearConversation()
                await agentLoop.clearHistoryWithCheckpoint()
                lastUserPrompt = nil
                // Start a fresh persisted session so the cleared conversation
                // does not overwrite the one just saved under this id.
                currentSessionId = UUID().uuidString
                continue
            }
            if commandInput == "/context" {
                let report = await agentLoop.contextUsageReport()
                for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                    await renderer.printScrollLine(String(line))
                }
                continue
            }
            if commandInput == "/compact" {
                let result = await agentLoop.compactContextManually()
                await renderer.printScrollLine(result)
                continue
            }
            if commandInput == "/skills" {
                if skillMetadata.isEmpty {
                    await renderer.printScrollLine("No skills discovered in workspace.")
                } else {
                    await renderer.printScrollLine("Discovered skills (\(skillMetadata.count)):")
                    for skill in skillMetadata {
                        let tags = skill.tags.isEmpty ? "" : " [tags: \(skill.tags.joined(separator: ", "))]"
                        await renderer.printScrollLine("- \(skill.name): \(skill.description) (\(skill.filePath))\(tags)")
                    }
                }
                continue
            }
            if commandInput == "/hooks" {
                let names = await hooks.registeredHookNames()
                if names.isEmpty {
                    await renderer.printScrollLine("No hooks registered.")
                } else {
                    await renderer.printScrollLine("Active hooks (\(names.count)):")
                    for name in names {
                        await renderer.printScrollLine("- \(name)")
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/transforms") {
                let arg = String(commandInput.dropFirst("/transforms".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if arg == "clear" {
                    await agentLoop.removeAllContextTransforms()
                    await renderer.printScrollLine("All context transforms removed.")
                } else {
                    let count = await agentLoop.contextTransformCount
                    if count == 0 {
                        await renderer.printScrollLine("No context transforms registered.")
                    } else {
                        await renderer.printScrollLine("Context transforms registered: \(count)")
                        await renderer.printScrollLine("Use '/transforms clear' to remove all.")
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/save-history-json") {
                let parts = commandInput.split(separator: " ", maxSplits: 1)
                let outputPath = parts.count > 1 ? String(parts[1]) : "session-history.json"
                do {
                    _ = try await agentLoop.exportHistoryJSON(to: outputPath)
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Failed to export JSON history: \(error.localizedDescription)\(DesignSystem.reset)")
                }
                continue
            }
            if commandInput.hasPrefix("/save-history") {
                let parts = commandInput.split(separator: " ", maxSplits: 1)
                let outputPath = parts.count > 1 ? String(parts[1]) : "session-history.md"
                do {
                    _ = try await agentLoop.exportHistory(to: outputPath)
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Failed to export history: \(error.localizedDescription)\(DesignSystem.reset)")
                }
                continue
            }
            if commandInput.hasPrefix("/load-history-json") {
                let parts = commandInput.split(separator: " ", maxSplits: 1)
                let inputPath = parts.count > 1 ? String(parts[1]) : "session-history.json"
                do {
                    _ = try await agentLoop.loadHistoryJSON(from: inputPath)
                    lastUserPrompt = await agentLoop.history.latestUserMessage
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Failed to load JSON history: \(error.localizedDescription)\(DesignSystem.reset)")
                }
                continue
            }
            if commandInputLower == "/resume" || commandInputLower.hasPrefix("/resume ") {
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /resume unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                let arg = String(commandInput.dropFirst("/resume".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if arg.lowercased() == "remove" {
                    // No id given: open a picker of recent sessions for this
                    // workspace, same as the bare-`/resume` picker below. Each
                    // entry submits `/resume remove <id>` on selection.
                    let sessions = SessionStore.list(cwd: workspaceRoot)
                        .filter { $0.id != currentSessionId }
                    if sessions.isEmpty {
                        await renderer.printScrollLine("\(DesignSystem.dim)No saved sessions to remove in this directory.\(DesignSystem.reset)")
                        continue
                    }
                    let items = sessions.prefix(20).map { session -> (name: String, desc: String) in
                        (name: "/resume remove \(session.id)", desc: "\(relativeTimeDescription(session.updatedAt)) · \(session.title)")
                    }
                    await renderer.openCommandPalette(commands: Array(items))
                    await renderer.renderFooter()
                    continue
                }
                if arg.lowercased().hasPrefix("remove ") {
                    let id = String(arg.dropFirst("remove ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if SessionStore.delete(id: id) {
                        await renderer.printScrollLine("  \(DesignSystem.dim)✓ Session removed.\(DesignSystem.reset)")
                    } else {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Remove failed.\(DesignSystem.reset)")
                    }
                    await renderer.renderFooter()
                    continue
                }
                if arg.isEmpty {
                    // No id given: open a picker of recent sessions for this
                    // workspace. Each entry submits `/resume <id>` on selection.
                    let sessions = SessionStore.list(cwd: workspaceRoot)
                        .filter { $0.id != currentSessionId }
                    if sessions.isEmpty {
                        await renderer.printScrollLine("\(DesignSystem.dim)No saved sessions to resume in this directory.\(DesignSystem.reset)")
                        continue
                    }
                    let items = sessions.prefix(20).map { session -> (name: String, desc: String) in
                        (name: "/resume \(session.id)", desc: "\(relativeTimeDescription(session.updatedAt)) · \(session.title)")
                    }
                    await renderer.openCommandPalette(commands: Array(items))
                    await renderer.renderFooter()
                    continue
                }
                _ = await restoreSession(id: arg)
                continue
            }
            if commandInput == "/help" || commandInput == "?" {
                for line in helpLines() {
                    await renderer.printScrollLine(line)
                }
                continue
            }
            if commandInput == "/retry" {
                // activeStreamTask, not renderer.getIsGenerating(): a turn stays
                // "in flight" through tool execution (e.g. a slow bash call), but
                // isGenerating already clears once the model finishes emitting
                // text, well before tools run. Gating on isGenerating let /retry
                // start a second, concurrent turn while the first was still
                // running its tool calls.
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /retry unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                guard let retryPrompt = lastUserPrompt else {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ nothing to retry\(DesignSystem.reset)")
                    continue
                }
                await renderer.printScrollLine("\(DesignSystem.dim)↻ retrying last prompt\(DesignSystem.reset)")
                let userEntry = SessionEntry(role: .user, content: retryPrompt)
                await renderer.printScrollLine(userEntry.render())
                activeStreamTask = Task { @MainActor in
                    defer {
                        activeStreamTask = nil
                        endOrchestratorCaffeinate()
                    }
                    await beginOrchestratorCaffeinate()
                    do {
                        try await agentLoop.processUserMessage(retryPrompt)
                    } catch is CancellationError {
                        // abortGeneration() already printed "· Aborted" and cleaned up the UI.
                    } catch {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(error.localizedDescription)\(DesignSystem.reset)")
                    }
                    await renderer.flushStreamLine()
                    await renderer.setPendingCount(0)
                    await renderer.renderFooter()
                    await saveCurrentSession()
                }
                continue
            }
            if commandInput == "/undo" || commandInput == "/revert" {
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /undo unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                await agentLoop.undoLastTurn()
                lastUserPrompt = await agentLoop.history.latestUserMessage
                await renderer.setPendingCount(0)
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/plan" {
                let isInPlan = await agentLoop.mode == .plan
                if isInPlan {
                    await agentLoop.setMode(.agent, taskType: .coding)
                } else {
                    await agentLoop.setMode(.plan)
                }
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/autopilot" {
                let currentMode = await agentLoop.mode
                let currentTaskType = await agentLoop.taskType
                let isAutopilot = currentMode != .plan && currentTaskType == .general
                if isAutopilot {
                    await agentLoop.setMode(.agent, taskType: .coding)
                } else {
                    await agentLoop.setMode(.agent, taskType: .general)
                }
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/agent" {
                await agentLoop.setMode(.agent)
                await renderer.renderFooter()
                continue
            }
            if commandInput == "/merge-approval" {
                await agentLoop.runMergeApprovalShortcutFlow()
                continue
            }
            if commandInput.hasPrefix("/gittree") {
                await handleGitTreeCommand(input: commandInput, agentLoop: agentLoop, renderer: renderer)
                continue
            }
            if commandInput.hasPrefix("/memory") {
                let sub = String(commandInput.dropFirst("/memory".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if sub == "remove" || sub == "edit" {
                    if activeStreamTask != nil {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Cannot edit/remove entries while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                        await renderer.renderFooter()
                    } else {
                        let isEdit = sub == "edit"
                        memoryFlowTask?.cancel()
                        memoryFlowTask = Task { @MainActor in
                            defer { memoryFlowTask = nil }
                            if isEdit {
                                if let entry = await handleMemoryInteractiveEdit(
                                    workspaceRoot: workspaceRoot,
                                    frontend: frontend,
                                    renderer: renderer
                                ) {
                                    pendingEditEntry = entry
                                    await renderer.setInputBuffer(entry.content)
                                    await renderer.moveCursorToEnd()
                                    await renderer.setStatusNotice("Editing memory entry — press Enter to save, Esc to cancel")
                                    await renderer.renderFooter()
                                } else {
                                    await renderer.renderFooter()
                                }
                            } else {
                                await handleMemoryInteractiveRemove(
                                    workspaceRoot: workspaceRoot,
                                    frontend: frontend,
                                    renderer: renderer
                                )
                                await renderer.renderFooter()
                            }
                        }
                    }
                } else {
                    await handleMemoryCommand(trimmed: commandInput, workspaceRoot: workspaceRoot, frontend: frontend)
                    await renderer.renderFooter()
                }
                continue
            }
            if commandInput.hasPrefix("/steer") {
                let msg = String(commandInput.dropFirst("/steer".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    await agentLoop.steer(msg)
                    await renderer.printScrollLine("↩️  Steering message queued: \"\(msg)\"")
                } else {
                    let pending = await agentLoop.pendingSteeringMessages()
                    if pending.isEmpty {
                        await renderer.printScrollLine("No steering messages queued.")
                    } else {
                        await renderer.printScrollLine("Queued steering messages (\(pending.count)):")
                        for (index, item) in pending.enumerated() {
                            await renderer.printScrollLine("  \(index + 1). \(item)")
                        }
                    }
                }
                continue
            }
            if commandInput.hasPrefix("/followup") {
                let msg = String(commandInput.dropFirst("/followup".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    await agentLoop.queueFollowUp(msg)
                    await renderer.printScrollLine("🔄 Follow-up queued: \"\(msg)\"")
                } else {
                    let pending = await agentLoop.pendingFollowUps()
                    if pending.isEmpty {
                        await renderer.printScrollLine("No follow-ups queued.")
                    } else {
                        await renderer.printScrollLine("Queued follow-ups (\(pending.count)):")
                        for (index, item) in pending.enumerated() {
                            await renderer.printScrollLine("  \(index + 1). \(item)")
                        }
                    }
                }
                continue
            }
            if let (workflow, command) = ["/discovery": Workflow.discovery, "/feature": Workflow.feature, "/fix": Workflow.fix]
                .first(where: { commandInput == $0.key || commandInputLower.hasPrefix($0.key + " ") })
                .map({ ($0.value, $0.key) }) {
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(command) unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                let input = String(commandInput.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !input.isEmpty else {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Usage: \(command) <description> — runs the deterministic '\(workflow.name)' pipeline (stage order is fixed in code, not chosen by the model). \(workflowCommandUsageHints[command] ?? "")\(DesignSystem.reset)")
                    continue
                }
                await renderer.printScrollLine("\(DesignSystem.dim)⚙ \(command) — running '\(workflow.name)' pipeline for: \(input)\(DesignSystem.reset)")
                lastUserPrompt = input
                activeStreamTask = Task { @MainActor in
                    defer {
                        activeStreamTask = nil
                        endOrchestratorCaffeinate()
                    }
                    await beginOrchestratorCaffeinate()
                    let result = await agentLoop.runWorkflow(workflow, input: input)
                    await renderer.flushStreamLine()
                    await renderer.printScrollLine(result.summary)
                    await renderer.setPendingCount(0)
                    await renderer.renderFooter()
                }
                continue
            }
            if commandInput == "/workflow" || commandInputLower.hasPrefix("/workflow ") {
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /workflow unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                let rest = String(commandInput.dropFirst("/workflow".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = rest.split(separator: " ", maxSplits: 1)
                guard let name = parts.first, let workflow = Workflow.builtin(named: String(name)) else {
                    let known = Workflow.builtins.map(\.name).joined(separator: ", ")
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Usage: /workflow <name> <description> — known workflows: \(known). Prefer /discovery, /feature, or /fix directly.\(DesignSystem.reset)")
                    continue
                }
                let input = parts.count > 1 ? String(parts[1]) : ""
                guard !input.isEmpty else {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Usage: /workflow \(name) <description>\(DesignSystem.reset)")
                    continue
                }
                await renderer.printScrollLine("\(DesignSystem.dim)⚙ /workflow — running '\(workflow.name)' pipeline for: \(input)\(DesignSystem.reset)")
                lastUserPrompt = input
                activeStreamTask = Task { @MainActor in
                    defer {
                        activeStreamTask = nil
                        endOrchestratorCaffeinate()
                    }
                    await beginOrchestratorCaffeinate()
                    let result = await agentLoop.runWorkflow(workflow, input: input)
                    await renderer.flushStreamLine()
                    await renderer.printScrollLine(result.summary)
                    await renderer.setPendingCount(0)
                    await renderer.renderFooter()
                }
                continue
            }
            if commandInputLower.hasPrefix("/ask ") || commandInputLower == "/ask" {
                let question: String
                if commandInput == "/ask" {
                    question = ""
                } else {
                    question = String(commandInput.dropFirst("/ask ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if question.isEmpty {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Usage: /ask <question>\(DesignSystem.reset)")
                    continue
                }
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /ask unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                let askUserEntry = SessionEntry(role: .user, content: question)
                await renderer.printScrollLine(askUserEntry.render())
                await renderer.printScrollLine("\(DesignSystem.dim)[ask] Side question (main context will be restored after).\(DesignSystem.reset)")
                activeStreamTask = Task { @MainActor in
                    defer {
                        activeStreamTask = nil
                        endOrchestratorCaffeinate()
                    }
                    await beginOrchestratorCaffeinate()
                    do {
                        try await agentLoop.processEphemeralMessage(question)
                        await renderer.printScrollLine("\(DesignSystem.dim)[ask] Side question answered. Main context restored.\(DesignSystem.reset)")
                    } catch is CancellationError {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)[ask] Generation cancelled.\(DesignSystem.reset)")
                    } catch {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(error.localizedDescription)\(DesignSystem.reset)")
                    }
                    await renderer.flushStreamLine()
                    await renderer.setPendingCount(0)
                    await renderer.renderFooter()
                }
                continue
            }
            if let shortcut = TUITaskShortcutParser.parse(commandInput) {
                if activeStreamTask != nil {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ /\(shortcut.profile) unavailable while a turn is in progress. Press Esc first.\(DesignSystem.reset)")
                    continue
                }
                let shortcutUserEntry = SessionEntry(role: .user, content: commandInput)
                await renderer.printScrollLine(shortcutUserEntry.render())
                await renderer.printScrollLine("\(DesignSystem.dim)[\(shortcut.profile)] Direct sub-agent dispatch (bypassing orchestrator reasoning).\(DesignSystem.reset)")
                activeStreamTask = Task { @MainActor in
                    defer {
                        activeStreamTask = nil
                        endOrchestratorCaffeinate()
                    }
                    await beginOrchestratorCaffeinate()
                    let result = await agentLoop.dispatchTaskShortcut(profile: shortcut.profile, message: shortcut.message)
                    if result.isError {
                        await renderer.printScrollLine("\(DesignSystem.brightRed)[\(shortcut.profile)] Sub-agent failed.\(DesignSystem.reset)")
                    } else {
                        await renderer.printScrollLine("\(DesignSystem.dim)[\(shortcut.profile)] Done.\(DesignSystem.reset)")
                    }
                    await renderer.flushStreamLine()
                    await renderer.setPendingCount(0)
                    await renderer.renderFooter()
                }
                continue
            }
            if commandInputLower.hasPrefix("/model") {
                let modelArg = String(commandInput.dropFirst("/model".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if modelArg == "free" {
                    modelFilterMode = .freeOnly
                    sessionModels = rebuildSessionModels(base: frontend.appConfig.models, filterMode: modelFilterMode)
                    await renderer.setAutocompleteProvider(makeAutocompleteProvider())
                    await renderer.printScrollLine("  Model filter: free remote models only.")
                    await renderer.renderFooter()
                    continue
                }
                if modelArg == "all" || modelArg == "reset" {
                    modelFilterMode = .all
                    sessionModels = rebuildSessionModels(base: frontend.appConfig.models, filterMode: modelFilterMode)
                    await renderer.setAutocompleteProvider(makeAutocompleteProvider())
                    await renderer.printScrollLine("  Model filter: all models.")
                    await renderer.renderFooter()
                    continue
                }
                await handleModelCommand(input: commandInput, models: sessionModels, agentLoop: agentLoop, renderer: renderer)
                continue
            }
            if commandInput.hasPrefix("/login") || commandInput.hasPrefix("/logout") {
                loginWizardStep = await handleLoginCommand(input: commandInput, renderer: renderer)
                sessionModels = rebuildSessionModels(base: frontend.appConfig.models, filterMode: modelFilterMode)
                await renderer.setAutocompleteProvider(makeAutocompleteProvider())
                continue
            }
            if commandInput.hasPrefix("/effort") || commandInput.hasPrefix("/thinking") {
                await handleEffortCommand(input: commandInput, agentLoop: agentLoop, renderer: renderer)
                continue
            }
            if commandInput.hasPrefix("/caffeinate") {
                await handleCaffeinateCommand(
                    input: commandInput,
                    manager: caffeinateManager,
                    renderer: renderer,
                    manuallyPinned: &caffeinateManuallyPinned
                )
                continue
            }

            // !<cmd> runs a shell command and keeps output in transcript.
            // !!<cmd> runs a shell command but suppresses transcript/history capture.
            let shellParse = TUIShellCommandParser.parse(commandInput)
            if let cmd = shellParse.command {
                if cmd.isEmpty {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ no command to run\(DesignSystem.reset)")
                } else {
                    await runShellCommand(cmd, renderer: renderer, suppressHistory: shellParse.suppressHistory)
                }
                continue
            }

            // Expand @file references before sending to the agent.
            let expandedPrompt = AtFileReferenceExpander.expand(trimmed, workspaceRoot: workspaceRoot)
            let effectivePrompt = expandedPrompt

            // Render user turn
            let userEntry = SessionEntry(role: .user, content: trimmed)
            await renderer.printScrollLine(userEntry.render())
            lastUserPrompt = trimmed

            // If a generation is already in flight, queue this prompt as a
            // steering message so AgentCore injects it before the next round.
            // The frontend's spinner-tick task continues uninterrupted.
            //
            // Use activeStreamTask != nil rather than renderer.getIsGenerating()
            // here. The renderer's flag is cleared asynchronously via the event
            // queue, so there is a window where the stream task has finished
            // (activeStreamTask = nil via defer) but the renderer still reports
            // isGenerating = true. Messages submitted in that window would be
            // queued as steering with no running task to consume them. Checking
            // activeStreamTask is authoritative: both reads/writes happen on
            // @MainActor, so there is no race.
            if activeStreamTask != nil {
                await agentLoop.steer(effectivePrompt)
                let pending = await agentLoop.pendingSteeringMessages().count
                await renderer.setPendingCount(pending)
                await renderer.renderFooter()
                continue
            }

            activeStreamTask = Task { @MainActor in
                defer {
                    activeStreamTask = nil
                    endOrchestratorCaffeinate()
                }
                await beginOrchestratorCaffeinate()
                do {
                    let parsed = ImageAttachmentParser.parse(prompt: effectivePrompt)
                    if !parsed.imageURLs.isEmpty {
                        await renderer.printScrollLine(
                            "\(DesignSystem.dim)  Attaching \(parsed.imageURLs.count) image(s): \(parsed.imageURLs.map(\.lastPathComponent).joined(separator: ", "))\(DesignSystem.reset)"
                        )
                    }
                    try await agentLoop.processUserMessage(parsed.cleanedPrompt, images: parsed.imageURLs)
                    while let followUp = await agentLoop.dequeueFollowUp() {
                        await renderer.printScrollLine("🔄 Auto follow-up: \"\(followUp)\"")
                        await hooks.emit(.followUpStarted(message: followUp))
                        do {
                            try await agentLoop.processUserMessage(followUp)
                        } catch is CancellationError {
                            await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Follow-up cancelled.\(DesignSystem.reset)")
                            await agentLoop.clearFollowUpQueue()
                            break
                        } catch {
                            await renderer.printScrollLine("\(DesignSystem.brightRed)✗ Follow-up error: \(error.localizedDescription)\(DesignSystem.reset)")
                            await agentLoop.clearFollowUpQueue()
                            break
                        }
                    }
                } catch is CancellationError {
                    // abortGeneration() already printed "· Aborted" and cleaned up the UI.
                } catch {
                    await renderer.printScrollLine("\(DesignSystem.brightRed)✗ \(error.localizedDescription)\(DesignSystem.reset)")
                }
                await renderer.flushStreamLine()
                await renderer.setPendingCount(0)
                await renderer.renderFooter()
                await saveCurrentSession()
            }

        default:
            break
        }
    }

    if shouldQuit {
        let wasGenerating = await renderer.getIsGenerating()
        let runningTask = activeStreamTask
        runningTask?.cancel()
        if wasGenerating {
            await frontend.abortGeneration()
        }
        if let runningTask {
            await runningTask.value
        }
        // TokenIterator uses asyncEval pipelining. Ensure pending MLX work is
        // fully drained before process teardown to avoid shutdown races.
        MLX.Stream().synchronize()
    }
    pendingResizeTask?.cancel()
    sigwinchSource?.cancel()
    sigwinchSource = nil
    pendingTypedFlushTask?.cancel()
    if let provider = voiceProvider, voiceTask != nil {
        provider.requestStop()
    }
    voiceSpinnerTask?.cancel()
    voiceSpinnerTask = nil
    voiceTask?.cancel()
    voiceTask = nil
    memoryFlowTask?.cancel()
    memoryFlowTask = nil
    await flushPendingTypedChunk(&pendingTypedChunk, renderer: renderer)
    await renderer.flushStreamLine()
    await renderer.teardownScreen()

    // Final persist and report the resume handle to the caller. Only surfaced
    // when the transcript actually has a human turn worth resuming (otherwise no
    // file was written and there is nothing to resume).
    await saveCurrentSession()
    guard let session = try? SessionStore.load(id: currentSessionId) else {
        return nil
    }
    return SessionResumeInfo(id: session.id, title: session.title)
}

private func normalizedCommandInput(from input: String) -> String {
    var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.first == ">" {
        normalized.removeFirst()
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalized
}

@MainActor
private func flushPendingTypedChunk(_ pending: inout String, renderer: Renderer) async {
    await flushPendingTypedChunk(&pending, renderer: renderer, render: true)
}

@MainActor
private func flushPendingTypedChunk(_ pending: inout String, renderer: Renderer, render: Bool) async {
    guard !pending.isEmpty else { return }
    let normalized = pending
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    pending.removeAll(keepingCapacity: true)
    await renderer.insertText(normalized)
    await normalizeInputSoftWrap(renderer: renderer)
    if render {
        await renderer.renderFooter()
    }
}

@MainActor
private func normalizeInputSoftWrap(renderer: Renderer) async {
    let original = await renderer.getInputBuffer()
    let originalCursor = await renderer.getCursorPos()
    let footerWidth = max(1, await renderer.currentCols() - 1)
    let isAutopilot = await renderer.isAutopilotEnabled()

    let wrapped = wrappedInputTextForSoftWrap(
        original,
        cursor: originalCursor,
        footerWidth: footerWidth,
        isAutopilot: isAutopilot
    )

    guard wrapped.text != original else { return }
    await renderer.setInputBuffer(wrapped.text)
    // Renderer no longer exposes direct cursor setters; reposition from end.
    await renderer.moveCursorToEnd()
    let movesLeft = max(0, wrapped.text.count - wrapped.cursor)
    if movesLeft > 0 {
        for _ in 0..<movesLeft {
            await renderer.moveCursorLeft()
        }
    }
}

func wrappedInputTextForSoftWrap(
    _ input: String,
    cursor: Int,
    footerWidth: Int,
    isAutopilot: Bool
) -> (text: String, cursor: Int) {
    let firstPrefixWidth: Int
    let rawPrefix: String

    if input.hasPrefix("!!") {
        rawPrefix = "!!"
        firstPrefixWidth = 3
    } else if input.hasPrefix("!") {
        rawPrefix = "!"
        firstPrefixWidth = 2
    } else {
        rawPrefix = ""
        firstPrefixWidth = isAutopilot ? 4 : 2
    }

    let display = String(input.dropFirst(rawPrefix.count))
    let displayCursor = max(0, min(display.count, cursor - rawPrefix.count))
    let continuationPrefixWidth = 2

    var out = ""
    out.reserveCapacity(display.count + max(1, display.count / max(1, footerWidth - continuationPrefixWidth)))

    var seen = 0
    var cursorOut = 0
    var col = 0
    var lineWidth = max(1, footerWidth - firstPrefixWidth)

    for ch in display {
        if ch == "\n" {
            out.append(ch)
            if seen < displayCursor { cursorOut += 1 }
            seen += 1
            col = 0
            lineWidth = max(1, footerWidth - continuationPrefixWidth)
            continue
        }

        let w = max(1, VisibleWidth.measure(String(ch)))
        if col + w > lineWidth {
            out.append("\n")
            if seen < displayCursor { cursorOut += 1 }
            col = 0
            lineWidth = max(1, footerWidth - continuationPrefixWidth)
        }

        out.append(ch)
        if seen < displayCursor { cursorOut += 1 }
        seen += 1
        col += w
    }

    return (rawPrefix + out, rawPrefix.count + cursorOut)
}

private func modeIndex(
    workingMode: AgentLoop.WorkingMode,
    taskType: AgentLoop.TaskType,
    thinkingLevel: String,
    appConfig: AppConfig
) -> Int? {
    let modePrefix: String
    if workingMode == .plan {
        modePrefix = "plan"
    } else if taskType == .general {
        modePrefix = "autopilot"
    } else {
        modePrefix = "coding"
    }
    let effort = thinkingLevel == "fast" ? "off" : thinkingLevel
    let id = "\(modePrefix)-\(effort)"
    if let exact = appConfig.modes.firstIndex(where: { $0.id == id }) {
        return exact
    }
    return appConfig.modes.firstIndex(where: { $0.id == "\(modePrefix)-low" })
}

/// Compact "3m ago" / "2h ago" / "5d ago" label for the /resume picker.
private func relativeTimeDescription(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    switch seconds {
    case 0..<60:      return "just now"
    case 60..<3600:   return "\(seconds / 60)m ago"
    case 3600..<86400: return "\(seconds / 3600)h ago"
    default:          return "\(seconds / 86400)d ago"
    }
}

private func statusModeLabel(workingMode: AgentLoop.WorkingMode, taskType: AgentLoop.TaskType) -> String {
    if workingMode == .plan { return "plan" }
    if taskType == .general { return "autopilot" }
    return ""
}

private func decisionForOption(_ index: Int?) -> ApprovalDecision {
    switch index {
    case 0: return .allowOnce
    case 1: return .allowAlwaysForCommand
    case 2: return .allowAllAutopilot
    case 3: return .deny(suggestion: nil)
    default: return .deny(suggestion: nil)
    }
}

private func planModeDecisionForOption(_ index: Int?) -> ApprovalDecision {
    switch index {
    case 0: return .switchToAgentAndAllow
    default: return .deny(suggestion: nil)
    }
}

@MainActor
private func runShellCommand(_ cmd: String, renderer: Renderer, suppressHistory: Bool) async {
    // Render the shell invocation as a tool_call entry.
    if suppressHistory {
        await renderer.printScrollLine("\(DesignSystem.dim)$ \(cmd)\(DesignSystem.reset)")
    } else {
        let callEntry = SessionEntry(role: .toolCall, content: "bash \(cmd)")
        await renderer.printScrollLine(callEntry.render())
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", cmd]
    let pipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errPipe
    do {
        try process.run()
        let output = await Task.detached(priority: .userInitiated) {
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            let status = process.terminationStatus
            return (out, err, status)
        }.value
        let (out, err, status) = output
        // Combine stdout and stderr; append exit-code hint on non-zero exit.
        var body = (out + err).trimmingCharacters(in: .newlines)
        if status != 0 { body += (body.isEmpty ? "" : "\n") + "exit \(status)" }
        if body.isEmpty { body = "(no output)" }
        if suppressHistory {
            await renderer.printScrollLine(body)
        } else {
            let outputEntry = SessionEntry(role: .toolOutput, content: body)
            await renderer.printScrollLine(outputEntry.render())
        }
    } catch {
        if suppressHistory {
            await renderer.printScrollLine("✗ \(error.localizedDescription)")
        } else {
            let errEntry = SessionEntry(role: .toolOutput, content: "✗ \(error.localizedDescription)")
            await renderer.printScrollLine(errEntry.render())
        }
    }
}

private func helpLines() -> [String] {
    [
        "  /caffeinate [on|off|busy|<dur>]  prevent system sleep (e.g. /caffeinate 2h)",
        "  /clear   clear the conversation",
        "  /help    this message",
        "  /memory  memory commands (save/log/search/list/undo/status/snippet/remove/edit)",
        "  /context show context usage",
        "  /skills  list discovered skills",
        "  /model   open model chooser; /model <name|id|number> to switch",
        "  /model free  show only free OpenRouter models in /model picker",
        "  /model all   clear model filter and show all models",
        "  /effort [level] set reasoning effort: off, minimal, low, medium, high",
        "  /login  add or update a remote provider in config.json (multi-step wizard)",
        "  /logout [id] remove a configured remote provider",
        "  /save-history [path] save session transcript as markdown",
        "  /save-history-json [path] save session transcript as json",
        "  /load-history-json [path] load prior session transcript",
        "  /resume [id] resume a saved session (no id opens a picker)",
        "  /resume remove  remove a saved session (interactive picker)",
        "  /retry   re-run the last user prompt",
        "  /undo    undo the last conversation turn",
        "  /plan    toggle plan mode on/off",
        "  /autopilot toggle autopilot on/off",
        "  /agent   switch to agent mode",
        "  /steer [msg] queue/list steering messages",
        "  /followup [msg] queue/list follow-ups",
        "  /ask [question] ask a quick side question without changing main context",
        "  /discovery <description> requirements still unclear — research→plan, then asks before implementing",
        "  /feature <description> requirements already settled — research→plan→execute→review, no pause",
        "  /fix <description> known bug — deterministic diagnose→fix→verify pipeline",
        "  /workflow <name> <description> run any built-in workflow by name",
        "  /merge-approval run merge approval flow",
        "  /gittree run git tree flow",
        "  /quit    exit the TUI",
        "  ! <cmd>  run a shell command and keep output in transcript/context",
        "  !!<cmd>  run a shell command without adding output to transcript/context",
        "  @path    attach a file — content is inlined into the prompt (tab-complete with @)",
        "  Enter to submit · Ctrl+C to cancel · Ctrl+L to redraw",
    ]
}

@MainActor
private func handleEffortCommand(
    input: String,
    agentLoop: AgentLoop,
    renderer: Renderer
) async {
    guard let intent = TUIEffortCommandParser.resolve(input: input) else {
        return
    }

    switch intent {
    case .openMenu(let isLegacyAlias):
        let current = await agentLoop.thinkingLevel
        await renderer.openCommandPalette(commands: TUIEffortCommandParser.menuItems(currentLevel: current))
        await renderer.renderFooter()
        if isLegacyAlias {
            await renderer.printScrollLine("  Tip: /thinking is a legacy alias. Prefer /effort.")
        }
    case .setLevel(let targetLevel, let isLegacyAlias):
        await agentLoop.setThinkingLevel(targetLevel)
        await renderer.printScrollLine("  Reasoning effort set to \(effortDisplayLabel(for: targetLevel)).")
        if isLegacyAlias {
            await renderer.printScrollLine("  Tip: /thinking is a legacy alias. Prefer /effort.")
        }
    case .invalidLevel(let levelArg, _):
        await renderer.printScrollLine(
            "  Invalid effort '\(levelArg)'. Use: off, minimal, low, medium, high."
        )
    }
}

private func effortDisplayLabel(for level: AgentLoop.ThinkingLevel) -> String {
    switch level {
    case .fast:
        return "off"
    default:
        return level.rawValue
    }
}

@MainActor
private func handleModelCommand(
    input: String,
    models: [AppConfig.ModelConfig],
    agentLoop: AgentLoop,
    renderer: Renderer
) async {
    guard let intent = TUIModelCommandParser.resolve(input: input, models: models) else {
        return
    }

    switch intent {
    case .openRootMenu:
        await renderer.openCommandPalette(commands: TUIModelCommandParser.rootMenuItems())
        await renderer.renderFooter()

    case .openLocalMenu:
        let currentModel = await renderer.getCurrentModelLabel()
        let items = TUIModelCommandParser.localMenuItems(models: models, currentModelLabel: currentModel)
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No local models in ~/models/.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()

    case .selectLocal(let id):
        // Find the local model in the session list, or synthesize a config.
        let index = models.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        let model = index.map { models[$0] } ?? AppConfig.ModelConfig(id: id, label: id)
        await switchToModel(model: model, index: index ?? models.count, agentLoop: agentLoop, renderer: renderer)

    case .openRemoteProvidersMenu:
        let items = TUIModelCommandParser.remoteProvidersMenuItems()
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No remote providers configured. Add them to ~/.mlx-coder/config.json.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()

    case .openRemoteModelsMenu(let provider):
        await openRemoteModelsMenu(provider: provider, renderer: renderer)

    case .refreshRemote(let provider):
        await refreshRemoteCatalog(providerID: provider, renderer: renderer)
        await openRemoteModelsMenu(provider: provider, renderer: renderer)

    case .selectRemote(let provider, let modelID):
        let carrier = InferenceBackend.remote(providerID: provider, modelID: modelID).modelPath
        let synthetic = AppConfig.ModelConfig(id: carrier, label: carrier)
        await switchToModel(model: synthetic, index: models.count, agentLoop: agentLoop, renderer: renderer)

    case .selectExisting(let index):
        guard models.indices.contains(index) else {
            await renderer.printScrollLine("  Invalid model index \(index + 1).")
            return
        }
        await switchToModel(model: models[index], index: index, agentLoop: agentLoop, renderer: renderer)

    case .openFilteredMenu(let query):
        let currentModel = await renderer.getCurrentModelLabel()
        let items = TUIModelCommandParser.filteredMenuItems(
            query: query,
            models: models,
            currentModelLabel: currentModel
        )
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No models match '\(query)'.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()

    case .invalidModelName(let name):
        // Allow a raw carrier (`<provider>:<model>`, e.g. `openrouter:qwen/…`) to be typed
        // directly even if not in the picker. AgentLoop accepts any modelPath;
        // we just validate the carrier shape here.
        if InferenceBackend(modelPath: name).isOnline {
            let synthetic = AppConfig.ModelConfig(id: name, label: name)
            await switchToModel(model: synthetic, index: models.count, agentLoop: agentLoop, renderer: renderer)
            return
        }
        let preview = models.prefix(8).map(\.label).joined(separator: ", ")
        await renderer.printScrollLine("  Unknown model '\(name)'. Some available: \(preview)…")

    case .openRoleMenu:
        let current = AgentRoleRegistry.current(workspaceRoot: agentLoop.projectWorkspaceRoot)
        await renderer.openCommandPalette(commands: TUIModelCommandParser.roleMenuItems(current: current))
        await renderer.renderFooter()

    case .openRoleActionMenu(let role):
        let current = AgentRoleRegistry.current(workspaceRoot: agentLoop.projectWorkspaceRoot)[role]
        await renderer.openCommandPalette(commands: TUIModelCommandParser.roleActionMenuItems(role: role, current: current))
        await renderer.renderFooter()

    case .openRoleLocalMenu(let role):
        let current = AgentRoleRegistry.current(workspaceRoot: agentLoop.projectWorkspaceRoot)[role]
        let items = TUIModelCommandParser.roleLocalMenuItems(role: role, models: models, current: current)
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No local models in ~/models/.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()

    case .selectRoleLocal(let role, let id):
        await setRoleModel(role: role, carrier: id, agentLoop: agentLoop, renderer: renderer)

    case .openRoleRemoteProvidersMenu(let role):
        let items = TUIModelCommandParser.remoteProvidersMenuItems().map { item in
            (name: item.name.replacingOccurrences(of: "/model remote", with: "/model role \(role) remote"), desc: item.desc)
        }
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No remote providers configured. Add them to ~/.mlx-coder/config.json.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()

    case .openRoleRemoteModelsMenu(let role, let provider):
        let current = AgentRoleRegistry.current(workspaceRoot: agentLoop.projectWorkspaceRoot)[role]
        let providerName = RemoteProviderRegistry.provider(id: provider)?.name ?? provider
        let items = TUIModelCommandParser.roleRemoteModelsMenuItems(role: role, provider: provider, current: current)
        guard !items.isEmpty else {
            await renderer.printScrollLine("  No cached models for \(providerName). Run /model remote \(provider) refresh first.")
            return
        }
        await renderer.openCommandPalette(commands: items)
        await renderer.renderFooter()

    case .selectRoleRemote(let role, let provider, let modelID):
        let carrier = InferenceBackend.remote(providerID: provider, modelID: modelID).modelPath
        await setRoleModel(role: role, carrier: carrier, agentLoop: agentLoop, renderer: renderer)

    case .clearRole(let role):
        do {
            try AgentRoleRegistry.clear(role: role)
            await agentLoop.registerToolsInternal()
            await renderer.printScrollLine("  ✓ Cleared \(role) — now uses the orchestrator's own model.")
        } catch {
            await renderer.printScrollLine("\(DesignSystem.brightRed)  Failed to update config: \(error.localizedDescription)\(DesignSystem.reset)")
        }

    case .invalidRole(let name):
        let roles = AgentRolesConfig.roleNames.joined(separator: ", ")
        await renderer.printScrollLine("  Unknown role '\(name)'. Available roles: \(roles).")
    }
}

/// Persists a role→model assignment and immediately refreshes the live
/// session's TaskTool so `task(profile: <role>)` picks it up without a restart.
@MainActor
private func setRoleModel(role: String, carrier: String, agentLoop: AgentLoop, renderer: Renderer) async {
    do {
        try AgentRoleRegistry.set(role: role, model: carrier)
        await agentLoop.registerToolsInternal()
        await renderer.printScrollLine("  ✓ \(role.capitalized) now uses \(carrier).")
    } catch {
        await renderer.printScrollLine("\(DesignSystem.brightRed)  Failed to update config: \(error.localizedDescription)\(DesignSystem.reset)")
    }
}

@MainActor
private func openRemoteModelsMenu(provider: String, renderer: Renderer) async {
    let providerConfig = RemoteProviderRegistry.provider(id: provider)
    let providerName = providerConfig?.name ?? provider
    let currentModel = await renderer.getCurrentModelLabel()
    let items = TUIModelCommandParser.remoteModelsMenuItems(provider: provider, currentModelLabel: currentModel)

    if providerConfig != nil && providerConfig?.hasAPIKey == false {
        await renderer.printScrollLine("  \(providerName) has no API key set — add one to ~/.mlx-coder/config.json if the provider requires it.")
    }
    // items always has at least the "refresh" row; hint when nothing cached.
    if items.count <= 1 {
        await renderer.printScrollLine("  No cached models for \(providerName). Run /model remote \(provider) refresh.")
    }
    await renderer.openCommandPalette(commands: items)
    await renderer.renderFooter()
}

@MainActor
private func refreshRemoteCatalog(providerID: String, renderer: Renderer) async {
    let providerName = RemoteProviderRegistry.provider(id: providerID)?.name ?? providerID
    await renderer.printScrollLine("  Refreshing \(providerName) model list…")
    do {
        let models = try await RemoteModelCache.refresh(providerID: providerID)
        await renderer.printScrollLine("  ✓ Loaded \(models.count) tool-capable \(providerName) models. Open /model to browse.")
    } catch {
        await renderer.printScrollLine(
            "\(DesignSystem.brightRed)  Failed to refresh \(providerName) models: \(error.localizedDescription)\(DesignSystem.reset)"
        )
    }
}

/// Recombines the bootstrap model list (from `appConfig`) with the freshly
/// regenerated online catalog entries. Stripping the previous online rows by
/// `openrouter:` prefix keeps the result clean across repeated refreshes.
@MainActor
private func rebuildSessionModels(
    base: [AppConfig.ModelConfig],
    filterMode: ModelFilterMode
) -> [AppConfig.ModelConfig] {
    let localOnly = base.filter { !InferenceBackend(modelPath: $0.id).isOnline }
    let onlineFilter: OnlineModelCatalog.Filter = (filterMode == .freeOnly) ? .freeOnly : .all
    return localOnly + OnlineModelCatalog.entries(filter: onlineFilter)
}

@MainActor
private func handleGitTreeCommand(
    input: String,
    agentLoop: AgentLoop,
    renderer: Renderer
) async {
    guard let intent = TUIGitTreeCommandParser.resolve(input: input) else {
        return
    }

    switch intent {
    case .openMenu:
        await renderer.openCommandPalette(commands: TUIGitTreeCommandParser.menuItems())
        await renderer.renderFooter()
    case .switchWorktree:
        await agentLoop.runGitTreeSwitchShortcutFlow()
    case .deleteBranch:
        await agentLoop.runGitTreeBranchDeleteShortcutFlow()
    case .invalidOption(let option):
        await renderer.printScrollLine(
            "  Unknown /gittree option '\(option)'. Try /gittree switch or /gittree delete-branch."
        )
    }
}

@MainActor
private func switchToModel(
    model: AppConfig.ModelConfig,
    index: Int,
    agentLoop: AgentLoop,
    renderer: Renderer,
    deferReload: Bool = false
) async {
    // Online providers carry their identifier in `model.id` as `<provider>:<model>`.
    // We don't probe the local model directory for those. Block the switch only
    // when the provider isn't configured in ~/.mlx-coder/config.json at all — the
    // AgentLoop generation path would just throw an unknown-provider error otherwise.
    let backend = InferenceBackend(modelPath: model.id)
    if let providerID = backend.providerID, !RemoteProviderRegistry.isConfigured(providerID) {
        await renderer.printScrollLine(
            "  \(model.label): provider '\(providerID)' is not configured. Add it to ~/.mlx-coder/config.json, then re-select this model."
        )
        return
    }

    let modelPath: String
    if backend.isOnline {
        // Online identifiers are the carrier — pass them through unchanged.
        modelPath = model.id
    } else {
        modelPath = localModelExists(model.id) ? model.id : "~/models/\(model.id)"
    }
    // Keep deferred reload for local-model cycling (fast Ctrl+P iteration), but
    // switch immediately to online backends when idle so local weights are
    // unloaded right away and RAM is reclaimed.
    let isGenerating = await renderer.getIsGenerating()
    let shouldDeferReload = deferReload && (!backend.isOnline || isGenerating)
    if !shouldDeferReload {
        await renderer.printScrollLine("  Switching to \(model.label)…")
    }
    do {
        if shouldDeferReload {
            try await agentLoop.stageModelSwitch(to: modelPath)
        } else {
            try await agentLoop.switchModel(to: modelPath)
        }
        await renderer.setCurrentModelIndex(index)
        // `index` may be out of range for synthetic/dynamic models (remote models
        // not in config). Override the status-bar label explicitly in that case.
        if index >= (await renderer.getConfigModelCount()) {
            await renderer.setModelLabel(model.label)
        }
        if !shouldDeferReload {
            await renderer.printScrollLine("  Active model: \(model.label)")
        }
        await renderer.renderFooter()
    } catch {
        await renderer.printScrollLine(
            "\(DesignSystem.brightRed)  Error: \(error.localizedDescription)\(DesignSystem.reset)"
        )
    }
}

@MainActor
private func cycleModelShortcut(
    models: [AppConfig.ModelConfig],
    defaultIndex: Int,
    agentLoop: AgentLoop,
    renderer: Renderer,
    reverse: Bool,
    deferReload: Bool
) async {
    guard !models.isEmpty else {
        await renderer.printScrollLine("  No models configured.")
        return
    }

    let currentLabel = await renderer.getCurrentModelLabel()
    let fallbackIndex = max(0, min(defaultIndex, models.count - 1))
    let currentIndex = models.firstIndex {
        $0.label.caseInsensitiveCompare(currentLabel) == .orderedSame
    } ?? fallbackIndex

    guard let targetIndex = cycledModelIndex(from: currentIndex, count: models.count, reverse: reverse) else {
        return
    }

    await switchToModel(
        model: models[targetIndex],
        index: targetIndex,
        agentLoop: agentLoop,
        renderer: renderer,
        deferReload: deferReload
    )
}

@MainActor
private func handleCaffeinateCommand(
    input: String,
    manager: CaffeinateManager,
    renderer: Renderer,
    manuallyPinned: inout Bool
) async {
    guard let intent = CaffeinateCommandParser.resolve(input: input) else { return }

    switch intent {
    case .openMenu:
        await renderer.openCommandPalette(commands: CaffeinateCommandParser.menuItems())
        await renderer.renderFooter()

    case .on:
        manuallyPinned = true
        await manager.enable(mode: .on)
        await renderer.printScrollLine(
            "\(DesignSystem.dim)Caffeinate: \(await manager.statusDescription)\(DesignSystem.reset)"
        )
        await renderer.renderFooter()

    case .busy:
        manuallyPinned = true
        await manager.enable(mode: .busy)
        await renderer.printScrollLine(
            "\(DesignSystem.dim)Caffeinate: \(await manager.statusDescription)\(DesignSystem.reset)"
        )
        await renderer.renderFooter()

    case .off:
        manuallyPinned = false
        await manager.disable()
        await renderer.printScrollLine(
            "\(DesignSystem.dim)Caffeinate: off\(DesignSystem.reset)"
        )
        await renderer.renderFooter()

    case .duration(let seconds):
        manuallyPinned = true
        await manager.enable(mode: .duration(seconds: seconds))
        await renderer.printScrollLine(
            "\(DesignSystem.dim)Caffeinate: \(await manager.statusDescription)\(DesignSystem.reset)"
        )
        await renderer.renderFooter()

    case .invalid(let arg):
        await renderer.printScrollLine(
            "\(DesignSystem.brightRed)Unknown caffeinate option '\(arg)'. Usage: /caffeinate [on|off|busy|<duration>]\(DesignSystem.reset)"
        )
        await renderer.renderFooter()
    }
}

func cycledModelIndex(from currentIndex: Int, count: Int, reverse: Bool) -> Int? {
    guard count > 0 else { return nil }
    let normalizedIndex = max(0, min(currentIndex, count - 1))
    if reverse {
        return (normalizedIndex - 1 + count) % count
    }
    return (normalizedIndex + 1) % count
}
