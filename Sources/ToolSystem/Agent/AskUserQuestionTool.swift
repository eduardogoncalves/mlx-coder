// Sources/ToolSystem/Agent/AskUserQuestionTool.swift
// Pause the turn to ask the human one or more multiple-choice clarifying
// questions — mirrors Claude Code's / opencode's AskUserQuestion UI.

import Foundation

/// Lets the model ask the user structured clarifying questions instead of
/// guessing or asking in free-form prose. Each question gets a short header
/// chip, 2-4 concrete options (plus an automatic "Other" free-text choice
/// the UI adds), and can allow picking more than one option.
///
/// The frontend owns the actual picker UI (see `ClarifyingQuestionsRequest`
/// in `AgentFrontend`); this tool only validates arguments, forwards the
/// request, and formats the answers back into the model's tool-call history.
public struct AskUserQuestionTool: Tool {
    public let name = "ask_user_question"
    public let description = "Ask the user one or more multiple-choice clarifying questions when their request is ambiguous or you need a decision only they can make (e.g. which of several valid approaches to take). Prefer this over guessing silently or asking in free-form prose — it lets the user pick from concrete options instead of typing an answer. Each question needs 2-4 short, mutually distinct options; the UI automatically adds an 'Other' choice so the user can always type something else. Use multi_select only when more than one option can reasonably apply at once. Do not use this for routine tool-approval decisions (those already have their own confirmation flow) or when you can reasonably infer the answer yourself."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "questions": PropertySchema(
                type: "array",
                description: "1-4 questions to ask together.",
                items: PropertySchema(
                    type: "object",
                    properties: [
                        "header": PropertySchema(type: "string", description: "Very short label for this question (max ~12 chars), shown as a chip, e.g. 'Auth method'."),
                        "question": PropertySchema(type: "string", description: "The full question text shown to the user."),
                        "multi_select": PropertySchema(type: "boolean", description: "Whether the user may pick more than one option. Defaults to false."),
                        "options": PropertySchema(
                            type: "array",
                            description: "2-4 concrete choices for this question.",
                            items: PropertySchema(
                                type: "object",
                                properties: [
                                    "label": PropertySchema(type: "string", description: "Short option text (1-5 words)."),
                                    "description": PropertySchema(type: "string", description: "Optional one-sentence elaboration of what picking this option means."),
                                ],
                                required: ["label"]
                            )
                        ),
                    ],
                    required: ["header", "question", "options"]
                )
            ),
        ],
        required: ["questions"]
    )

    private let frontend: any AgentFrontend

    public init(frontend: any AgentFrontend) {
        self.frontend = frontend
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawQuestions = arguments["questions"] as? [[String: Any]], !rawQuestions.isEmpty else {
            return .error("Missing required argument: questions (a non-empty array of {header, question, options, multi_select?})")
        }

        var questions: [ClarifyingQuestion] = []
        for (index, raw) in rawQuestions.enumerated() {
            guard let header = (raw["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
                return .error("questions[\(index)] is missing required field: header")
            }
            guard let questionText = (raw["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !questionText.isEmpty else {
                return .error("questions[\(index)] is missing required field: question")
            }
            guard let rawOptions = raw["options"] as? [[String: Any]], !rawOptions.isEmpty else {
                return .error("questions[\(index)] is missing required field: options (a non-empty array of {label, description?})")
            }

            var options: [ClarifyingOption] = []
            for (optionIndex, rawOption) in rawOptions.enumerated() {
                guard let label = (rawOption["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                    return .error("questions[\(index)].options[\(optionIndex)] is missing required field: label")
                }
                let description = (rawOption["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                options.append(ClarifyingOption(label: label, description: description))
            }

            let multiSelect = (raw["multi_select"] as? Bool) ?? (raw["multiSelect"] as? Bool) ?? false
            questions.append(ClarifyingQuestion(header: header, question: questionText, options: options, multiSelect: multiSelect))
        }

        let response = await frontend.request(.clarifyingQuestions(ClarifyingQuestionsRequest(questions: questions)))
        guard case .clarifyingQuestions(let answers) = response, let answers, answers.count == questions.count else {
            return .success("The user did not answer — the question prompt was cancelled or dismissed. Proceed using your best judgement, or ask again in a plain message if you need to.")
        }

        var lines: [String] = []
        for (question, answer) in zip(questions, answers) {
            let answerText = answer.selectedLabels.isEmpty ? "(no selection)" : answer.selectedLabels.joined(separator: ", ")
            lines.append("[\(question.header)] \(question.question)\nAnswer: \(answerText)")
        }
        return .success(lines.joined(separator: "\n\n"))
    }
}
