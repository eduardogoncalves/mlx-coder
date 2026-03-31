// Sources/CLI/StreamRenderer.swift
// Renders streaming output to terminal with ANSI colors

import Foundation

import Darwin

/// Renders streaming agent output to the terminal.
public final class StreamRenderer: @unchecked Sendable {

    /// Whether to show thinking blocks.
    public let verbose: Bool
    
    // State for streaming thinking blocks line-by-line
    private var needsPrefix = true

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    // MARK: - ANSI Colors

    private static let reset     = "\u{001B}[0m"
    private static let bold      = "\u{001B}[1m"
    private static let dim       = "\u{001B}[2m"
    private static let cyan      = "\u{001B}[36m"
    private static let yellow    = "\u{001B}[33m"
    private static let green     = "\u{001B}[32m"
    private static let red       = "\u{001B}[31m"
    private static let magenta   = "\u{001B}[35m"
    private static let lineDim   = "\u{001B}[38;5;60m"

    /// Print a text chunk from the model.
    public func printChunk(_ text: String) {
        print(text, terminator: "")
        fflush(stdout)
    }

    /// Print a thinking block (only if verbose).
    public func printThinking(_ text: String) {
        print("\(Self.dim)+ \(text)\(Self.reset)")
    }
    
    public func startThinking() {
        needsPrefix = true
    }
    
    public func printThinkingChunk(_ text: String) {
        var output = ""
        for char in text {
            if needsPrefix {
                output += "\(Self.dim)+ "
                needsPrefix = false
            }
            output += String(char)
            if char == "\n" {
                needsPrefix = true
            }
        }
        print("\(Self.dim)\(output)\(Self.reset)", terminator: "")
        fflush(stdout)
    }
    
    public func endThinking() {
        if !needsPrefix {
            print() // ensure we end on a new line
        }
        needsPrefix = true
    }

    /// Print a tool call about to be executed (Top of the box).
    public func printToolCall(name: String, arguments: [String: Any]) {
        if verbose {
            var payload: [String: Any] = [
                "name": name,
                "arguments": arguments
            ]

            let jsonText: String
            if JSONSerialization.isValidJSONObject(payload),
               let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let encoded = String(data: data, encoding: .utf8) {
                jsonText = encoded
            } else {
                payload = ["name": name, "arguments": String(describing: arguments)]
                jsonText = String(describing: payload)
            }

            print("<tool_call>")
            print(jsonText)
            print("</tool_call>")
        }

        let argsString = arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        let width = getTerminalWidth()
        let topBorder = String(repeating: "─", count: max(0, width - 2))

        print("\n\(Self.lineDim)╭\(topBorder)\(Self.reset)")
        print("\(Self.lineDim)│\(Self.reset) \(Self.bold)\(Self.yellow)🔧 \(name)\(Self.reset)\(Self.dim)(\(argsString))\(Self.reset)")
    }

    /// Print a tool result (Bottom of the box).
    public func printToolResult(_ result: ToolResult) {
        let width = getTerminalWidth()
        let bottomBorder = String(repeating: "─", count: width - 2)
        
        let icon = result.isError ? "❌" : "✅"
        let color = result.isError ? Self.red : Self.green
        
        // Split result content by lines to prefix each with a vertical bar, or just print the first line if it's too long
        let lines = result.content.split(separator: "\n")
        if let firstLine = lines.first {
            let truncated = firstLine.count > width - 10 ? String(firstLine.prefix(width - 15)) + "..." : String(firstLine)
            print("\(Self.lineDim)│\(Self.reset) \(color)\(icon) \(truncated)\(Self.reset)")
        }
        
        if let marker = result.truncationMarker {
            print("\(Self.lineDim)│\(Self.reset) \(Self.dim)\(marker)\(Self.reset)")
        }
        
        print("\(Self.lineDim)╰\(bottomBorder)\(Self.reset)")
    }

    /// Print a status message.
    public func printStatus(_ message: String) {
        print("\(Self.dim)\(Self.magenta)▸ \(message)\(Self.reset)")
    }

    /// Print an error.
    public func printError(_ message: String) {
        print("\(Self.bold)\(Self.red)Error: \(message)\(Self.reset)")
    }

    /// Print the prompt indicator.
    public func printPrompt() {
        let width = getTerminalWidth()
        print("\n\(Self.lineDim)" + String(repeating: "─", count: width) + "\(Self.reset)")
        print("\(Self.bold)\(Self.magenta)>\(Self.reset) ", terminator: "")
        fflush(stdout)
    }
    
    public func printPromptFooter(contextPercent: Double, branchName: String? = nil, commitCount: Int = 0) {
        let width = getTerminalWidth()
        print("\(Self.lineDim)" + String(repeating: "─", count: width) + "\(Self.reset)")
        
        let shortcuts = "? for shortcuts"
        let contextInfo = String(format: "%.1f%% context used", contextPercent)
        
        // Build right-side info with optional git branch
        var rightInfo = contextInfo
        if let branch = branchName, !branch.isEmpty {
            let commitIndicator = commitCount > 0 ? " • (\(commitCount) commit\(commitCount == 1 ? "" : "s"))" : ""
            rightInfo = "Branch: \(branch)\(commitIndicator) | \(contextInfo)"
        }
        
        let spaces = width - shortcuts.count - rightInfo.count
        if spaces > 0 {
            print("\(Self.dim)\(shortcuts)" + String(repeating: " ", count: spaces) + "\(rightInfo)\(Self.reset)")
        } else {
            print("\(Self.dim)\(shortcuts) | \(rightInfo)\(Self.reset)")
        }
    }
    
    /// Clear the previous N lines from the terminal
    public func clearPreviousLines(count: Int) {
        guard count > 0 else { return }
        print("\r\u{001B}[\(count)A\u{001B}[J", terminator: "")
        fflush(stdout)
    }
    
    private func getTerminalWidth() -> Int {
        var width: Int = 80
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            width = Int(w.ws_col)
        }
        return width
    }
}
