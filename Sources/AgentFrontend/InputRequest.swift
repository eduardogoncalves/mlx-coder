// Sources/AgentFrontend/InputRequest.swift
// Synchronous Q&A requests the agent makes to the frontend (approval,
// option select, free-form text input). Each request has a matching
// response variant; frontends answer via `AgentFrontend.request(_:)`.

import Foundation

// MARK: - AgentRequest / AgentResponse

public enum AgentRequest: Sendable {
    case approval(ApprovalRequest)
    case optionSelect(OptionSelectRequest)
    case textInput(TextInputRequest)
    case clarifyingQuestions(ClarifyingQuestionsRequest)
}

public enum AgentResponse: Sendable {
    case approval(ApprovalDecision)
    case optionSelect(Int?)        // selected index, nil = cancelled
    case textInput(String?)        // entered text, nil = cancelled
    case clarifyingQuestions([ClarifyingAnswer]?)  // one per question, nil = cancelled
}

// MARK: - Approval

public struct ApprovalRequest: Sendable {
    public let toolName: String
    /// Pre-formatted single-line summary of what will run (e.g. `bash echo hi`).
    public let display: String
    /// Stable key used to cache "always allow this command" decisions.
    public let cacheKey: String
    public let isPlanModeBlock: Bool
    /// Optional structured arguments for richer UIs (string→string view).
    public let arguments: [String: String]

    public init(
        toolName: String,
        display: String,
        cacheKey: String,
        isPlanModeBlock: Bool,
        arguments: [String: String] = [:]
    ) {
        self.toolName = toolName
        self.display = display
        self.cacheKey = cacheKey
        self.isPlanModeBlock = isPlanModeBlock
        self.arguments = arguments
    }
}

public enum ApprovalDecision: Sendable {
    /// One-shot approval for this call only.
    case allowOnce
    /// Allow this exact command (cacheKey) for the rest of the session.
    case allowAlwaysForCommand
    /// Engage autopilot — auto-approve every subsequent tool call.
    case allowAllAutopilot
    /// Plan-mode only: switch to AGENT mode and allow.
    case switchToAgentAndAllow
    /// Reject. `suggestion` is an optional hint sent back to the model.
    case deny(suggestion: String?)
}

// MARK: - Option select

public struct OptionSelectRequest: Sendable {
    public let prompt: String
    public let options: [String]
    public let selectedIndex: Int
    /// When `true`, pressing Escape selects the **last** option instead of
    /// cancelling — matches `InteractiveInput.selectOption(escSelectsLastOption:)`.
    public let escSelectsLastOption: Bool
    public init(prompt: String, options: [String], selectedIndex: Int = 0, escSelectsLastOption: Bool = false) {
        self.prompt = prompt
        self.options = options
        self.selectedIndex = selectedIndex
        self.escSelectsLastOption = escSelectsLastOption
    }
}

// MARK: - Text input

public struct TextInputRequest: Sendable {
    public let prompt: String
    public let placeholder: String
    public let initialText: String
    public let multiline: Bool
    public init(prompt: String, placeholder: String = "", initialText: String = "", multiline: Bool = false) {
        self.prompt = prompt
        self.placeholder = placeholder
        self.initialText = initialText
        self.multiline = multiline
    }
}

// MARK: - Clarifying questions (model-initiated "ask the user" UI)

/// One choice within a `ClarifyingQuestion` — a short label plus an optional
/// longer description shown alongside it.
public struct ClarifyingOption: Sendable {
    public let label: String
    public let description: String
    public init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}

/// A single clarifying question the model wants to ask the user: a short
/// header chip (e.g. "Auth method"), the full question text, its options,
/// and whether more than one option may be chosen. Every question also gets
/// an implicit "Other" choice so the user can type a free-form answer.
public struct ClarifyingQuestion: Sendable {
    public let header: String
    public let question: String
    public let options: [ClarifyingOption]
    public let multiSelect: Bool
    public init(header: String, question: String, options: [ClarifyingOption], multiSelect: Bool = false) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// One or more clarifying questions to present together, mirroring Claude
/// Code / opencode's `AskUserQuestion`-style UI.
public struct ClarifyingQuestionsRequest: Sendable {
    public let questions: [ClarifyingQuestion]
    public init(questions: [ClarifyingQuestion]) {
        self.questions = questions
    }
}

/// One question's answer — the labels of every option the user chose, plus
/// any free-typed "Other" text appended last.
public struct ClarifyingAnswer: Sendable {
    public let selectedLabels: [String]
    public init(selectedLabels: [String]) {
        self.selectedLabels = selectedLabels
    }
}
