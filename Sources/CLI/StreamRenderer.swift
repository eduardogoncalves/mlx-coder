// Sources/CLI/StreamRenderer.swift
// Renders streaming output to terminal with ANSI colors

import Foundation

import Darwin

/// Renders streaming agent output to the terminal.
public final class StreamRenderer: @unchecked Sendable {

    /// Whether to show thinking blocks.
    public let verbose: Bool

    public var ui: TerminalUI?

    private var write: @Sendable (String) -> Void
    
    // State for streaming thinking blocks line-by-line
    private var needsPrefix = true

    public init(verbose: Bool = false, write: (@Sendable (String) -> Void)? = nil) {
        self.verbose = verbose
        self.write = write ?? { text in
            print(text, terminator: "")
            fflush(stdout)
        }
    }

    public func setWriter(_ write: @escaping @Sendable (String) -> Void) {
        self.write = write
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
        write(text)
    }

    /// Print a thinking block (only if verbose).
    public func printThinking(_ text: String) {
        write("\(Self.dim)+ \(text)\(Self.reset)\n")
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
        write("\(Self.dim)\(output)\(Self.reset)")
    }
    
    public func endThinking() {
        if !needsPrefix {
            write("\n")
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

            write("<tool_call>\n")
            write("\(jsonText)\n")
            write("</tool_call>\n")
        }

        let argsString = arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        let width = getTerminalWidth()
        let topBorder = String(repeating: "─", count: max(0, width - 2))

        write("\n\(Self.lineDim)╭\(topBorder)\(Self.reset)\n")
        write("\(Self.lineDim)│\(Self.reset) \(Self.bold)\(Self.yellow)🔧 \(name)\(Self.reset)\(Self.dim)(\(argsString))\(Self.reset)\n")
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
            write("\(Self.lineDim)│\(Self.reset) \(color)\(icon) \(truncated)\(Self.reset)\n")
        }
        
        if let marker = result.truncationMarker {
            write("\(Self.lineDim)│\(Self.reset) \(Self.dim)\(marker)\(Self.reset)\n")
        }
        
        write("\(Self.lineDim)╰\(bottomBorder)\(Self.reset)\n")
    }

    /// Print a status message.
    public func printStatus(_ message: String) {
        write("\(Self.dim)\(Self.magenta)▸ \(message)\(Self.reset)\n")
    }

    /// Print an error.
    public func printError(_ message: String) {
        write("\(Self.bold)\(Self.red)Error: \(message)\(Self.reset)\n")
    }

    /// Print the prompt indicator.
    public func printPrompt() {
        if ui != nil { return }
        let width = getTerminalWidth()
        print("\n\(Self.lineDim)" + String(repeating: "─", count: width) + "\(Self.reset)")
        print("\(Self.bold)\(Self.magenta)>\(Self.reset) ", terminator: "")
        fflush(stdout)
    }
    
    public func printPromptFooter(contextPercent: Double, branchName: String? = nil, commitCount: Int = 0) {
        if ui != nil { return }
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
        if ui != nil { return }
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
