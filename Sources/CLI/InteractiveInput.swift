// Sources/CLI/InteractiveInput.swift
// Handles raw terminal input with a border and footer that disappears on submit.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class InteractiveInput: @unchecked Sendable {
    private var history: [String] = []
    private var historyIndex: Int = 0
    private var currentInputBeforeHistory: String = ""
    
    public init() {}
    
    // ANSI Controls (same as StreamRenderer to match styling)
    private let reset     = "\u{001B}[0m"
    private let bold      = "\u{001B}[1m"
    private let dim       = "\u{001B}[2m"
    private let magenta   = "\u{001B}[35m"
    private let lineDim   = "\u{001B}[38;5;60m"
    
    private func getTerminalWidth() -> Int {
        var width: Int = 80
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            width = Int(w.ws_col)
        }
        return width
    }
    
    /// Reads a line from the user interactively, drawing a box and a footer below it.
    /// When the user submits (Enter), the box and footer are erased and only the plain text remains.
    public func readInteractive(contextPercent: Double? = nil, sandboxEnabled: Bool = false, version: String = "", mode initialMode: String = "", onModeToggle: (() async -> String)? = nil) async -> String? {
        var mode = initialMode
        // Ensure STDIN is a terminal, otherwise fallback to standard readLine
        guard isatty(STDIN_FILENO) == 1 else {
            // Unlikely to happen in normal interactive usage, but safe fallback
            print("\(magenta)>\(reset) ", terminator: "")
            fflush(stdout)
            return readLine(strippingNewline: true)
        }

        var originalTerm = termios()
        tcgetattr(STDIN_FILENO, &originalTerm)
        
        var rawTerm = originalTerm
        // Turn off ECHO, Canonical mode, and ISIG to read character by character without signals firing
        rawTerm.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        rawTerm.c_cc.16 = 1 // VMIN
        rawTerm.c_cc.17 = 0 // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTerm)
        // Enable bracketed paste mode so multiline paste can be handled as content.
        print("\u{1B}[?2004h", terminator: "")
        fflush(stdout)

        // Clear any stale escape-sequence tail bytes left by previous raw-mode listeners.
        tcflush(STDIN_FILENO, TCIFLUSH)
        
        defer {
            print("\u{1B}[?2004l", terminator: "")
            fflush(stdout)
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTerm)
        }
        
        var input = ""
        var cursorPosition = 0 // character index
        let width = getTerminalWidth()
        var isInitialDraw = true
        
        // Track the row the cursor is at relative to the top border (0).
        var currentCursorRowRelToTop = 0

        func insertTextAtCursor(_ text: String) {
            let index = input.index(input.startIndex, offsetBy: cursorPosition)
            input.insert(contentsOf: text, at: index)
            cursorPosition += text.count
        }

        func textMetrics(_ text: String, cursor: Int) -> (textRows: Int, cursorRow: Int, cursorCol: Int) {
            func advance(char: Character, row: inout Int, col: inout Int) {
                if char == "\n" {
                    row += 1
                    col = 0
                    return
                }

                col += 1
                if col >= width {
                    row += col / width
                    col = col % width
                }
            }

            var totalRow = 0
            var totalCol = 4 // Prompt prefix "❯ " + spacing.
            for ch in text {
                advance(char: ch, row: &totalRow, col: &totalCol)
            }

            var cursorRow = 0
            var cursorCol = 4
            var seen = 0
            for ch in text {
                if seen >= cursor { break }
                advance(char: ch, row: &cursorRow, col: &cursorCol)
                seen += 1
            }

            return (max(1, totalRow + 1), cursorRow, cursorCol)
        }

        func readBracketedPastePayload() -> String {
            let endSequence: [UInt8] = [27, 91, 50, 48, 49, 126] // ESC [ 2 0 1 ~
            var bytes: [UInt8] = []
            var window: [UInt8] = []

            while true {
                var b: UInt8 = 0
                if read(STDIN_FILENO, &b, 1) != 1 {
                    break
                }

                bytes.append(b)
                window.append(b)
                if window.count > endSequence.count {
                    window.removeFirst(window.count - endSequence.count)
                }

                if window == endSequence {
                    bytes.removeLast(endSequence.count)
                    break
                }
            }

            var text = String(decoding: bytes, as: UTF8.self)
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            text = text.replacingOccurrences(of: "\r", with: "\n")
            return text
        }
        
        func redraw() {
            if !isInitialDraw {
                // Move up to the top border position
                if currentCursorRowRelToTop > 0 {
                    print("\u{1B}[\(currentCursorRowRelToTop)A", terminator: "")
                }
                // Clear everything below
                print("\r\u{1B}[J", terminator: "")
            }
            isInitialDraw = false
            
            // 0: Top Border
            let topBorder = String(repeating: "─", count: max(1, width - 2))
            print("\r\(lineDim)╭\(topBorder)\(reset)")
            
            // 1..textRows: Prompt and input
            // By printing without \n at the end, if the text wraps, it relies on the terminal auto-wrap.
            // But to be consistent with VT100 cursor movement, we explicitly print chunks or just let it wrap.
            print("\r\(magenta)│ ❯ \(reset)\(input)", terminator: "")
            
            let metrics = textMetrics(input, cursor: cursorPosition)
            let textRows = metrics.textRows
            
            // If the text ended exactly at the right edge, the cursor might be "hanging" and 
            // printing the next char naturally wraps. We explicitly print a newline to move to the bottom border.
            print("")
            
            // textRows + 1: Bottom border
            let bottomBorder = String(repeating: "─", count: max(1, width - 2))
            print("\r\(lineDim)╰\(bottomBorder)\(reset)")
            
            // textRows + 2: Footer
            let shortcuts = "Enter send | Shift+Tab mode | ? shortcuts"
            let contextStr = contextPercent != nil ? String(format: "%.1f%% context used", contextPercent!) : ""
            var footerText = contextStr.isEmpty ? shortcuts : "\(shortcuts) | \(contextStr)"
            if !version.isEmpty {
                footerText += " | v\(version)"
            }
            
            let statusStr = sandboxEnabled ? "Enabled" : "Disabled"
            let statusColor = sandboxEnabled ? "\u{001B}[32m" : "\u{001B}[31m"
            let sandboxPrefix = "[Sandbox: "
            let sandboxSuffix = "]"
            
            let modeStr = mode.uppercased()
            let modeColor = mode.lowercased().hasPrefix("plan") ? "\u{001B}[33m" : "\u{001B}[32m"
            let modePrefix = "[Mode: "
            let modeSuffix = "]"
            
            let visibleFooterLen = footerText.count
            let visibleSandboxLen = sandboxPrefix.count + statusStr.count + sandboxSuffix.count
            let visibleModeLen = modePrefix.count + modeStr.count + modeSuffix.count
            
            let padding = max(1, width - visibleFooterLen - visibleSandboxLen - visibleModeLen - 2)
            
            let footerLine = "\r\(dim)\(footerText)\(reset)\(String(repeating: " ", count: padding))\(dim)\(modePrefix)\(reset)\(modeColor)\(modeStr)\(reset)\(dim)\(modeSuffix)\(reset) \(dim)\(sandboxPrefix)\(reset)\(statusColor)\(statusStr)\(reset)\(dim)\(sandboxSuffix)\(reset)"
            print(footerLine, terminator: "")
            
            // Now cursor is at the end of the footer line (row = textRows + 2).
            let currentFooterRow = textRows + 2
            let targetCursorRow = 1 + metrics.cursorRow
            let targetCol = metrics.cursorCol
            
            let totalUp = currentFooterRow - targetCursorRow
            if totalUp > 0 {
                print("\r\u{1B}[\(totalUp)A", terminator: "")
            } else {
                print("\r", terminator: "")
            }
            
            if targetCol > 0 {
                print("\u{1B}[\(targetCol)C", terminator: "")
            }
            
            fflush(stdout)
            
            currentCursorRowRelToTop = targetCursorRow
        }
        
        // Print empty space so we don't accidentally draw out of terminal bounds and shift the screen unpredictably
        print("\n\n\n\n", terminator: "")
        print("\u{1B}[4A", terminator: "")
        
        historyIndex = history.count
        currentInputBeforeHistory = ""
        
        redraw()
        
        while true {
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) != 1 { continue }
            
            if byte == 4 || byte == 3 { // Ctrl-D or Ctrl-C
                // Clear block
                if currentCursorRowRelToTop > 0 {
                    print("\r\u{1B}[\(currentCursorRowRelToTop)A", terminator: "")
                }
                print("\r\u{1B}[J", terminator: "")
                return nil
            } else if byte == 10 || byte == 13 { // Enter
                break
            } else if byte == 127 { // Backspace
                if cursorPosition > 0 {
                    let index = input.index(input.startIndex, offsetBy: cursorPosition - 1)
                    input.remove(at: index)
                    cursorPosition -= 1
                    redraw()
                }
            } else if byte == 27 { // Esc or Sequence
                let seq = TerminalKeyParser.readEscapeSequence(initialTimeoutMs: 100, extendedTimeoutMs: 200)
                
                if seq == [91, 50, 48, 48, 126] { // Bracketed paste start: ESC [ 200 ~
                    let pasted = readBracketedPastePayload()
                    if !pasted.isEmpty {
                        insertTextAtCursor(pasted)
                        redraw()
                    }
                } else if seq.count == 1 && seq[0] == 98 { // Option+Left (Esc b)
                    moveToPreviousWord(input: input, cursorPosition: &cursorPosition)
                    redraw()
                } else if seq.count == 1 && seq[0] == 102 { // Option+Right (Esc f)
                    moveToNextWord(input: input, cursorPosition: &cursorPosition)
                    redraw()
                } else if let direction = TerminalKeyParser.arrowDirection(for: seq) {
                    if direction == .right && cursorPosition < input.count {
                        cursorPosition += 1
                        redraw()
                    } else if direction == .left && cursorPosition > 0 {
                        cursorPosition -= 1
                        redraw()
                    } else if direction == .up {
                        if historyIndex > 0 {
                            if historyIndex == history.count {
                                currentInputBeforeHistory = input
                            }
                            historyIndex -= 1
                            input = history[historyIndex]
                            cursorPosition = input.count
                            redraw()
                        }
                    } else if direction == .down {
                        if historyIndex < history.count {
                            historyIndex += 1
                            if historyIndex == history.count {
                                input = currentInputBeforeHistory
                            } else {
                                input = history[historyIndex]
                            }
                            cursorPosition = input.count
                            redraw()
                        }
                    }
                } else if seq.count >= 2 && (seq[0] == 91 || seq[0] == 79) {
                    let type = seq.last!
                    if type == 90 { // Shift+Tab (Z)
                        if let toggle = onModeToggle {
                            mode = await toggle()
                            redraw()
                        }
                    }
                }
            } else if byte >= 32 { // Printable characters
                // Proper UTF8 decoding for multi-byte
                var bytes = [byte]
                var expectedLen = 1
                if byte & 0xE0 == 0xC0 { expectedLen = 2 }
                else if byte & 0xF0 == 0xE0 { expectedLen = 3 }
                else if byte & 0xF8 == 0xF0 { expectedLen = 4 }
                
                while bytes.count < expectedLen {
                    var nextByte: UInt8 = 0
                    if read(STDIN_FILENO, &nextByte, 1) == 1 {
                        bytes.append(nextByte)
                    } else {
                        break
                    }
                }
                
                if let str = String(bytes: bytes, encoding: .utf8) {
                    insertTextAtCursor(str)
                    redraw()
                }
            }
        }
        
        // Final Clear
        if currentCursorRowRelToTop > 0 {
            print("\r\u{1B}[\(currentCursorRowRelToTop)A", terminator: "")
        }
        print("\r\u{1B}[J", terminator: "")
        
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            history.append(trimmed)
            if history.count > 100 { history.removeFirst() }
        }
        
        // Print the plain submitted input without border and footer
        print("\r\(magenta)❯\(reset) \(input)")
        
        return input
    }

    /// Displays a simple arrow-key picker and returns the selected option index.
    /// Up/Down moves the selection; Enter confirms; Escape or Ctrl-C cancels.
    public func selectOption(prompt: String, options: [String]) async -> Int? {
        guard !options.isEmpty else { return nil }

        guard isatty(STDIN_FILENO) == 1 else {
            return 0
        }

        var originalTerm = termios()
        tcgetattr(STDIN_FILENO, &originalTerm)

        var rawTerm = originalTerm
        rawTerm.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        rawTerm.c_cc.16 = 1
        rawTerm.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTerm)

        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTerm)
        }

        let title = prompt.isEmpty ? "Select a model" : prompt
        let footer = "Use Up/Down and Enter. Esc cancels."
        var selectedIndex = 0
        var isInitialDraw = true
        var renderedLineCount = 0

        func draw() {
            if !isInitialDraw {
                print("\u{1B}[\(renderedLineCount)A\r\u{1B}[J", terminator: "")
            }
            isInitialDraw = false

            print("\n\(bold)\(title)\(reset)")
            print("\(dim)\(footer)\(reset)")
            print("")

            for (index, option) in options.enumerated() {
                if index == selectedIndex {
                    print("\(bold)\u{001B}[32m>\(reset) \(option)")
                } else {
                    print("  \(option)")
                }
            }

            renderedLineCount = options.count + 4
            fflush(stdout)
        }

        draw()

        while true {
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) != 1 { continue }

            if byte == 3 || byte == 4 {
                if renderedLineCount > 0 {
                    print("\r\u{1B}[\(renderedLineCount)A", terminator: "")
                }
                print("\r\u{1B}[J", terminator: "")
                fflush(stdout)
                return nil
            } else if byte == 10 || byte == 13 {
                break
            } else if byte == 27 {
                let sequence = TerminalKeyParser.readEscapeSequence(initialTimeoutMs: 80, extendedTimeoutMs: 120)
                if sequence.isEmpty {
                    if renderedLineCount > 0 {
                        print("\r\u{1B}[\(renderedLineCount)A", terminator: "")
                    }
                    print("\r\u{1B}[J", terminator: "")
                    fflush(stdout)
                    return nil
                }

                if let direction = TerminalKeyParser.arrowDirection(for: sequence) {
                    switch direction {
                    case .up:
                        if selectedIndex > 0 {
                            selectedIndex -= 1
                            draw()
                        }
                    case .down:
                        if selectedIndex < options.count - 1 {
                            selectedIndex += 1
                            draw()
                        }
                    case .left, .right:
                        break
                    }
                }
            }
        }

        if renderedLineCount > 0 {
            print("\r\u{1B}[\(renderedLineCount)A", terminator: "")
        }
        print("\r\u{1B}[J", terminator: "")
        fflush(stdout)
        return selectedIndex
    }
    
    private func moveToPreviousWord(input: String, cursorPosition: inout Int) {
        if cursorPosition <= 0 { return }
        var pos = cursorPosition
        
        let chars = Array(input)
        // Skip leading spaces
        while pos > 0 && chars[pos - 1].isWhitespace {
            pos -= 1
        }
        // Skip to start of word
        while pos > 0 && !chars[pos - 1].isWhitespace {
            pos -= 1
        }
        cursorPosition = pos
    }

    private func moveToNextWord(input: String, cursorPosition: inout Int) {
        if cursorPosition >= input.count { return }
        var pos = cursorPosition
        
        let chars = Array(input)
        // Skip current word
        while pos < input.count && !chars[pos].isWhitespace {
            pos += 1
        }
        // Skip following spaces
        while pos < input.count && chars[pos].isWhitespace {
            pos += 1
        }
        cursorPosition = pos
    }
}
