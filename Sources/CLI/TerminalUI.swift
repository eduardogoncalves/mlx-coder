// Sources/CLI/TerminalUI.swift
// Full-screen alternate-screen TUI with persistent input box + streaming output pane.

import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class TerminalUI: @unchecked Sendable {
    private struct State {
        var output: String = ""
        var input: String = ""
        var cursor: Int = 0
        var mode: String = ""
        var sandboxEnabled: Bool = false
        var version: String = ""
        var generationActive: Bool = false
        var spinnerMessage: String? = nil
        var spinnerStart: Date? = nil
        var shouldExit: Bool = false
        var scrollOffset: Int = 0  // Line offset for scrolling through history
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

    public init(version: String, initialMode: String, sandboxEnabled: Bool) {
        stateLock.withLock {
            $0.version = version
            $0.mode = initialMode
            $0.sandboxEnabled = sandboxEnabled
            $0.cursor = 0
            $0.scrollOffset = 0
        }
    }

    // MARK: - External state updates (thread-safe)

    public func appendOutput(_ text: String) {
        stateLock.withLock {
            $0.output.append(text)
            $0.scrollOffset = 0  // Reset scroll when new content arrives
            if $0.output.count > 400_000 {
                $0.output = String($0.output.suffix(300_000))
            }
        }
    }

    public func setMode(_ mode: String) {
        stateLock.withLock { $0.mode = mode }
    }

    public func setSandboxEnabled(_ enabled: Bool) {
        stateLock.withLock { $0.sandboxEnabled = enabled }
    }

    public func setGenerationActive(_ active: Bool) {
        stateLock.withLock { $0.generationActive = active }
    }

    public func setSpinner(message: String?) {
        stateLock.withLock {
            $0.spinnerMessage = message
            if let message, !message.isEmpty {
                if $0.spinnerStart == nil { $0.spinnerStart = Date() }
            } else {
                $0.spinnerStart = nil
            }
        }
    }

    public func requestExit() {
        stateLock.withLock { $0.shouldExit = true }
    }

    // MARK: - Run loop

    public func run(
        onSubmit: @escaping @Sendable (String) async -> Void,
        onModeToggle: @escaping @Sendable () async -> String,
        onCancel: @escaping @Sendable () async -> Void
    ) async {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            // Non-interactive environment; best-effort fallback.
            while true {
                guard let line = readLine(strippingNewline: true) else { return }
                await onSubmit(line)
            }
        }

        var originalTerm = termios()
        tcgetattr(STDIN_FILENO, &originalTerm)

        var rawTerm = originalTerm
        rawTerm.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        rawTerm.c_cc.16 = 0 // VMIN
        rawTerm.c_cc.17 = 1 // VTIME (0.1s)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawTerm)

        // Alternate screen + hide cursor + bracketed paste + mouse support
        print("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[?1000h\u{1B}[?1015h\u{1B}[?1006h", terminator: "")
        fflush(stdout)

        defer {
            print("\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1000l\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l", terminator: "")
            fflush(stdout)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTerm)
        }

        // Avoid carrying buffered escape tails from previous raw-mode listeners.
        tcflush(STDIN_FILENO, TCIFLUSH)

        // Main loop: poll input + render at ~30 FPS.
        while true {
            // Exit check
            let shouldExit = stateLock.withLock { $0.shouldExit }
            if shouldExit { break }

            // Drain available bytes
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 0)
            if pr > 0, (pfd.revents & Int16(POLLIN)) != 0 {
                var b: UInt8 = 0
                while read(STDIN_FILENO, &b, 1) == 1 {
                    if b == 3 { // Ctrl+C exits app
                        requestExit()
                        break
                    }

                    if b == 27 { // ESC or escape sequence
                        let seq = TerminalKeyParser.readEscapeSequence(initialTimeoutMs: 8, extendedTimeoutMs: 30)
                        if seq.isEmpty {
                            await onCancel()
                        } else if let direction = TerminalKeyParser.arrowDirection(for: seq) {
                            switch direction {
                            case .left:  moveCursor(delta: -1)
                            case .right: moveCursor(delta: 1)
                            case .up:    scrollOutput(delta: 1)
                            case .down:  scrollOutput(delta: -1)
                            }
                        } else if seq.count >= 2 && (seq[0] == 91 || seq[0] == 79), seq.last == 90 {
                            let newMode = await onModeToggle()
                            setMode(newMode)
                        } else if seq == [91, 50, 48, 48, 126] { // Bracketed paste start
                            let pasted = readBracketedPastePayload()
                            if !pasted.isEmpty {
                                insertText(pasted)
                            }
                        } else if seq.count >= 3 && seq[0] == 91 && seq[1] == 60 {
                            // Mouse scroll wheel: [<64;x;y (scroll up) or [<65;x;y (scroll down)
                            if seq.count > 2 {
                                let wheelCode = seq[2]
                                if wheelCode == 52 {  // '4' = scroll up
                                    scrollOutput(delta: 1)
                                } else if wheelCode == 53 {  // '5' = scroll down
                                    scrollOutput(delta: -1)
                                }
                            }
                        }
                    } else if b == 10 || b == 13 { // Enter
                        let line = consumeInputLine()
                        await onSubmit(line)
                    } else if b == 127 || b == 8 { // Backspace
                        backspace()
                    } else if b == 21 { // Ctrl+U
                        clearInput()
                    } else if b >= 32 {
                        // UTF-8 decode multi-byte sequences
                        var bytes = [b]
                        var expectedLen = 1
                        if b & 0xE0 == 0xC0 { expectedLen = 2 }
                        else if b & 0xF0 == 0xE0 { expectedLen = 3 }
                        else if b & 0xF8 == 0xF0 { expectedLen = 4 }
                        while bytes.count < expectedLen {
                            var nb: UInt8 = 0
                            if read(STDIN_FILENO, &nb, 1) == 1 { bytes.append(nb) } else { break }
                        }
                        if let str = String(bytes: bytes, encoding: .utf8) {
                            insertText(str)
                        }
                    }

                    // Stop draining if no more input pending.
                    var inner = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    if poll(&inner, 1, 0) <= 0 { break }
                }
            }

            renderFrame()
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    // MARK: - Input editing

    private func insertText(_ text: String) {
        stateLock.withLock {
            let safe = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let sanitized = safe.replacingOccurrences(of: "\n", with: " ")
            let idx = $0.input.index($0.input.startIndex, offsetBy: min($0.cursor, $0.input.count))
            $0.input.insert(contentsOf: sanitized, at: idx)
            $0.cursor = min($0.input.count, $0.cursor + sanitized.count)
        }
    }

    private func moveCursor(delta: Int) {
        stateLock.withLock {
            $0.cursor = max(0, min($0.input.count, $0.cursor + delta))
        }
    }

    private func scrollOutput(delta: Int) {
        stateLock.withLock {
            let newOffset = $0.scrollOffset + delta
            $0.scrollOffset = max(0, newOffset)
        }
    }

    private func backspace() {
        stateLock.withLock {
            if $0.cursor > 0, !$0.input.isEmpty {
                let removeIndex = $0.input.index($0.input.startIndex, offsetBy: $0.cursor - 1)
                $0.input.remove(at: removeIndex)
                $0.cursor -= 1
            }
        }
    }

    private func clearInput() {
        stateLock.withLock {
            $0.input.removeAll(keepingCapacity: true)
            $0.cursor = 0
        }
    }

    private func consumeInputLine() -> String {
        let line = stateLock.withLock { st -> String in
            let line = st.input
            st.input.removeAll(keepingCapacity: true)
            st.cursor = 0
            return line
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rendering

    private func terminalSize() -> (rows: Int, cols: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return (rows: max(1, Int(w.ws_row)), cols: max(1, Int(w.ws_col)))
        }
        return (rows: 24, cols: 80)
    }

    private func stripANSIEscapes(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\u{1B}" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "[" {
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        let c = s[j]
                        if ("a"..."z").contains(c) || ("A"..."Z").contains(c) { j = s.index(after: j); break }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private func wrapLines(_ text: String, width: Int) -> [String] {
        guard width > 1 else { return [""] }
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        out.reserveCapacity(rawLines.count)
        for line in rawLines {
            // Keep ANSI in the stored line, but wrap by visible width.
            let visible = stripANSIEscapes(line)
            if visible.count <= width {
                out.append(line)
                continue
            }
            var current = ""
            current.reserveCapacity(width)
            var visibleCount = 0
            var i = line.startIndex
            while i < line.endIndex {
                let ch = line[i]
                if ch == "\u{1B}" {
                    // Copy escape sequence verbatim (doesn't add visible width).
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "[" {
                        current.append(ch)
                        var j = line.index(after: next)
                        current.append(line[next])
                        while j < line.endIndex {
                            let c = line[j]
                            current.append(c)
                            if ("a"..."z").contains(c) || ("A"..."Z").contains(c) {
                                j = line.index(after: j)
                                break
                            }
                            j = line.index(after: j)
                        }
                        i = j
                        continue
                    }
                }
                current.append(ch)
                visibleCount += 1
                i = line.index(after: i)
                if visibleCount >= width {
                    out.append(current)
                    current = ""
                    visibleCount = 0
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    private func renderFrame() {
        let snapshot = stateLock.withLock { $0 }

        let (rows, cols) = terminalSize()
        let inputWidth = max(10, cols - 4)
        let inputVisible = snapshot.input
        let inputWrapped = wrapLines(inputVisible, width: inputWidth)
        let inputInnerRows = min(4, max(1, inputWrapped.count))
        let inputBoxHeight = inputInnerRows + 2
        let footerHeight = 1
        let outputHeight = max(1, rows - inputBoxHeight - footerHeight)

        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        var spinnerPart = ""
        if let msg = snapshot.spinnerMessage, let start = snapshot.spinnerStart {
            let i = Int(Date().timeIntervalSince(start) / 0.08) % spinnerFrames.count
            spinnerPart = "\u{001B}[36m\(spinnerFrames[i])\u{001B}[0m \u{001B}[35m\(msg)\u{001B}[0m"
        } else if snapshot.generationActive {
            spinnerPart = "\u{001B}[36m⠿\u{001B}[0m \u{001B}[35mGenerating…\u{001B}[0m"
        }

        let modeStr = snapshot.mode.uppercased()
        let sandboxStr = snapshot.sandboxEnabled ? "\u{001B}[32mEnabled\u{001B}[0m" : "\u{001B}[31mDisabled\u{001B}[0m"
        let footerLeft = "\u{001B}[2mEnter send | Shift+Tab mode | Esc cancel\u{001B}[0m"
        var footerRight = "\u{001B}[2m[Mode: \u{001B}[0m\u{001B}[32m\(modeStr)\u{001B}[0m\u{001B}[2m] [Sandbox: \u{001B}[0m\(sandboxStr)\u{001B}[2m]\u{001B}[0m"
        if !snapshot.version.isEmpty {
            footerRight += " \u{001B}[2mv\(snapshot.version)\u{001B}[0m"
        }

        // Prepare output slice with scroll support
        let wrappedOutput = wrapLines(snapshot.output, width: max(1, cols))
        let totalLines = wrappedOutput.count
        let maxScroll = max(0, totalLines - outputHeight)
        let clampedScroll = min(snapshot.scrollOffset, maxScroll)
        let startIndex = max(0, totalLines - outputHeight - clampedScroll)
        let outputSlice = wrappedOutput.count > startIndex ? Array(wrappedOutput[startIndex...]) : []

        // Build frame in buffer to reduce flicker
        var buffer = ""
        buffer.reserveCapacity(10000)
        
        // Clear and home cursor
        buffer += "\u{1B}[H\u{1B}[2J"

        for line in outputSlice {
            if line.isEmpty {
                buffer += "\n"
            } else {
                buffer += line + "\n"
            }
        }

        // Pad to outputHeight
        let padCount = max(0, outputHeight - outputSlice.count)
        if padCount > 0 {
            for _ in 0..<padCount { buffer += "\n" }
        }

        // Input box
        let topBorder = String(repeating: "─", count: max(1, cols - 2))
        buffer += "\u{001B}[38;5;60m╭\(topBorder)╮\u{001B}[0m\n"
        for row in 0..<inputInnerRows {
            let content = row < inputWrapped.count ? inputWrapped[row] : ""
            let visibleLen = stripANSIEscapes(content).count
            let padNeeded = max(0, inputWidth - visibleLen)
            let padded = content + String(repeating: " ", count: padNeeded)
            buffer += "\u{001B}[38;5;60m│\u{001B}[0m \u{001B}[35m>\u{001B}[0m \(padded) \u{001B}[38;5;60m│\u{001B}[0m\n"
        }
        buffer += "\u{001B}[38;5;60m╰\(topBorder)╯\u{001B}[0m\n"

        // Footer line (compose, with optional spinnerPart)
        var footer = footerLeft
        if !spinnerPart.isEmpty {
            footer += "  \(spinnerPart)"
        }

        // Fit left + right into cols.
        let leftVisibleLen = stripANSIEscapes(footer).count
        let rightVisibleLen = stripANSIEscapes(footerRight).count
        let spaces = cols - leftVisibleLen - rightVisibleLen
        if spaces > 1 {
            footer += String(repeating: " ", count: spaces) + footerRight
        } else {
            footer += " " + footerRight
        }
        buffer += footer + "\n"

        // Write buffer to stdout
        print(buffer, terminator: "")

        // Position cursor inside the input box.
        // We approximate cursor placement by visible character count and wrapping width.
        let cursor = min(snapshot.cursor, snapshot.input.count)
        let prefixVisible = 3 // " > " spacing before text
        let absolutePos = prefixVisible + cursor
        let cursorRowRel = absolutePos / inputWidth
        let cursorColRel = absolutePos % inputWidth
        let cursorRow = outputHeight + 1 + 1 + min(cursorRowRel, inputInnerRows - 1) // output + top border + (row index starting at 1)
        let cursorCol = 1 + 1 + 2 + cursorColRel // left border + space + "> " + col
        print("\u{1B}[\(cursorRow);\(cursorCol)H", terminator: "")
        fflush(stdout)
    }

    private func readBracketedPastePayload() -> String {
        let endSequence: [UInt8] = [27, 91, 50, 48, 49, 126] // ESC [ 2 0 1 ~
        var bytes: [UInt8] = []
        var window: [UInt8] = []

        while true {
            var b: UInt8 = 0
            if read(STDIN_FILENO, &b, 1) != 1 { break }
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
}
