// Sources/AgentCore/AgentLoop+ToolApproval.swift
// Terminal-based tool approval UI and approval key helpers.

import Foundation
import Darwin

extension AgentLoop {

    static func menuOptionHint(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return (1...count).map(String.init).joined(separator: "/")
    }

    static func approvalCommandKey(toolName: String, arguments: [String: Any]?) -> String {
        guard toolName == "bash", let arguments else {
            return toolName
        }

        if JSONSerialization.isValidJSONObject(arguments),
           let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return "\(toolName) \(text)"
        }

        return "\(toolName) \(String(describing: arguments))"
    }

    static func approvalCommandDisplay(toolName: String, arguments: [String: Any]?) -> String {
        guard toolName == "bash", let arguments else {
            return toolName
        }

        let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return toolName
        }

        var otherArguments = arguments
        otherArguments.removeValue(forKey: "command")
        guard !otherArguments.isEmpty else {
            return "\(toolName) \(command)"
        }

        if JSONSerialization.isValidJSONObject(otherArguments),
           let data = try? JSONSerialization.data(withJSONObject: otherArguments, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return "\(toolName) \(command) \(text)"
        }

        return "\(toolName) \(command) \(String(describing: otherArguments))"
    }

    /// Prompt the user to approve a tool call using raw terminal mode.
    func askForToolApproval(name: String, arguments: [String: Any]? = nil, isPlanMode: Bool) async -> (approved: Bool, suggestion: String?) {
        let approvalCommand = Self.approvalCommandKey(toolName: name, arguments: arguments)
        let approvalCommandDisplay = Self.approvalCommandDisplay(toolName: name, arguments: arguments)

        // Global auto-approve mode for power users.
        if permissions.approvalMode == .yolo {
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: nil
            )
            return (true, nil)
        }

        // Auto-approve common edit operations while still guarding shell/task.
        if permissions.approvalMode == .autoEdit && !isPlanMode {
            let autoEditTools: Set<String> = ["write_file", "edit_file", "append_file", "patch"]
            if autoEditTools.contains(name) {
                await auditLogger?.logApprovalDecision(
                    toolName: name,
                    mode: mode.rawValue,
                    isPlanModePrompt: isPlanMode,
                    approved: true,
                    suggestion: nil
                )
                return (true, nil)
            }
        }

        if sessionApprovedToolCommands.contains(approvalCommand) && !isPlanMode {
            return (true, nil)
        }

        if autoApproveAllTools && !isPlanMode {
            return (true, nil)
        }

        await CancelController.shared.suspendListening()

        func resumeCancelListeningAndReturn(_ result: (approved: Bool, suggestion: String?)) async -> (approved: Bool, suggestion: String?) {
            await CancelController.shared.resumeListeningIfNeeded()
            return result
        }
        
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        
        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        rawTermios.c_cc.16 = 1  // VMIN - wait for at least 1 byte
        rawTermios.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)
        
        // Flush any stale bytes from stdin that may have been buffered
        // during async operations like Shift+Tab mode cycling.
        tcflush(STDIN_FILENO, TCIFLUSH)
        
        let commandScopedOption: String
        if approvalCommandDisplay.contains("'") {
            commandScopedOption = "Yes, allow \"\(approvalCommandDisplay)\" always in this session"
        } else {
            commandScopedOption = "Yes, allow '\(approvalCommandDisplay)' always in this session"
        }

        let options = isPlanMode ? [
            "Switch to AGENT mode and allow",
            "Stay in PLAN mode and deny with suggestion (esc)"
        ] : [
            "Yes, allow once",
            commandScopedOption,
            "Yes, allow all tool calls (autopilot mode)",
            "No, suggest changes (esc)"
        ]
        var selectedIndex = 0
        var menuDrawnOnce = false
        let optionHint = Self.menuOptionHint(options.count)
        let selectionHint = optionHint.isEmpty
            ? "Use arrows, Enter, or Esc."
            : "Use \(optionHint), arrows, Enter, or Esc."
        var footerHint = selectionHint
        
        func drawMenu() {
            if menuDrawnOnce {
                print("\u{1B}[\(options.count + 1)A", terminator: "")
            } else {
                print() // empty line only once at the start
            }
            
            let message = isPlanMode ? "Tool '\(name)' is blocked in PLAN mode. Switch to AGENT mode?" : "Do you want to proceed?"
            print("\r\u{1B}[K\(message)")
            for (i, option) in options.enumerated() {
                if i == selectedIndex {
                    print("\r\u{1B}[K\u{001B}[32m● \(i + 1). \(option)\u{001B}[0m")
                } else {
                    print("\r\u{1B}[K  \(i + 1). \(option)")
                }
            }
            print("\r\u{1B}[K\(footerHint) Waiting for user confirmation... [\(selectedIndex + 1)/\(options.count)]: ", terminator: "")
            fflush(stdout)
            
            menuDrawnOnce = true
        }
        
        // Hide cursor
        print("\u{1B}[?25l", terminator: "")
        renderer.printStatus("[Key mode] Approval required. \(footerHint)")
        drawMenu()
        
        var finalSelection = -1
        var shouldDrainInputTail = false
        
        while true {
            var byte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            if bytesRead <= 0 { continue }
            
            if byte == 27 { // ESC or escape sequence
                let seq = TerminalKeyParser.readEscapeSequence()
                let escapeKind = TerminalKeyParser.classifyEscapeSequence(seq)
                if escapeKind == .bare {
                    // Bare ESC — treat as deny/cancel
                    shouldDrainInputTail = true
                    finalSelection = isPlanMode ? 1 : (options.count - 1)
                    break
                }

                if let keypadSelection = TerminalKeyParser.numericSelection(forEscapeSequence: seq, optionCount: options.count) {
                    selectedIndex = keypadSelection
                    drawMenu()
                    finalSelection = keypadSelection
                    break
                }

                if let direction = TerminalKeyParser.arrowDirection(for: seq) {
                    if direction == .up {
                        selectedIndex = max(0, selectedIndex - 1)
                        footerHint = selectionHint
                        drawMenu()
                    } else if direction == .down {
                        selectedIndex = min(options.count - 1, selectedIndex + 1)
                        footerHint = selectionHint
                        drawMenu()
                    }
                } else {
                    // Alt-key combos or unsupported escape sequences are ignored.
                    shouldDrainInputTail = true
                    footerHint = "Unsupported key. \(selectionHint)"
                    drawMenu()
                }
            } else if byte == 10 || byte == 13 { // Enter
                finalSelection = selectedIndex
                break
            } else if let numericSelection = TerminalKeyParser.numericSelection(for: byte, optionCount: options.count) {
                selectedIndex = numericSelection
                footerHint = selectionHint
                drawMenu()
                finalSelection = numericSelection
                break
            } else if byte == 3 { // Ctrl+C
                // Restore terminal and exit completely
                tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
                print("\u{1B}[?25h\n")
                exit(1)
            } else {
                footerHint = "Unsupported key. \(selectionHint)"
                drawMenu()
            }
        }
        
        // Drain buffered tails only when we consumed partial escape sequences.
        if shouldDrainInputTail {
            TerminalKeyParser.drainAvailableInput()
        }
        
        // Restore terminal and show cursor
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        print("\u{1B}[?25h\n")

        if finalSelection == 0 {
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: nil
            )
            return await resumeCancelListeningAndReturn((true, nil))
        } else if finalSelection == 1 && !isPlanMode {
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: "session_command_auto_approve_enabled:\(LoopDetectionService.sanitizeAuditField(approvalCommand))"
            )
            sessionApprovedToolCommands.insert(approvalCommand)
            return await resumeCancelListeningAndReturn((true, nil))
        } else if finalSelection == 2 && !isPlanMode {
            autoApproveAllTools = true
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: true,
                suggestion: "session_autopilot_mode_enabled"
            )
            return await resumeCancelListeningAndReturn((true, nil))
        } else {
            // Last option or ESC: Suggest changes
            TerminalKeyParser.drainAvailableInput()
            var suggestionTerm = termios()
            tcgetattr(STDIN_FILENO, &suggestionTerm)
            var cookedTerm = suggestionTerm
            cookedTerm.c_lflag |= tcflag_t(ECHO | ICANON | ISIG)
            cookedTerm.c_cc.16 = 1
            cookedTerm.c_cc.17 = 0
            tcsetattr(STDIN_FILENO, TCSANOW, &cookedTerm)
            print("[\(name)] Blocked. Suggest changes (or press Enter to deny with no comment): ", terminator: "")
            fflush(stdout)
            guard let suggestion = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestion.isEmpty else {
                await auditLogger?.logApprovalDecision(
                    toolName: name,
                    mode: mode.rawValue,
                    isPlanModePrompt: isPlanMode,
                    approved: false,
                    suggestion: nil
                )
                return await resumeCancelListeningAndReturn((false, nil))
            }
            await auditLogger?.logApprovalDecision(
                toolName: name,
                mode: mode.rawValue,
                isPlanModePrompt: isPlanMode,
                approved: false,
                suggestion: suggestion
            )
            return await resumeCancelListeningAndReturn((false, suggestion))
        }
    }
}
