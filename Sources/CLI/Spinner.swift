// Sources/CLI/Spinner.swift
import Foundation
import Darwin

/// A simple terminal spinner for loading and processing states.
public actor Spinner {
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var isTaskRunning = false
    private var task: Task<Void, Never>?
    private var message: String
    private var startTime: Date?
    private var lastRenderedRows = 0
    private let ui: TerminalUI?
    
    public init(message: String, ui: TerminalUI? = nil) {
        self.message = message
        self.ui = ui
    }
    
    /// Starts the spinner animation in a detached task.
    public func start() {
        guard !isTaskRunning else { return }
        isTaskRunning = true

        if let ui {
            ui.setSpinner(message: message)
            return
        }

        let f = self.frames
        
        task = Task {
            self.startTime = Date()
            var i = 0
            while !Task.isCancelled {
                let frame = f[i % f.count]
                let duration = Int(Date().timeIntervalSince(self.startTime ?? Date()))
                let currentMessage = self.message
                let renderedRows = renderRowCount(frame: frame, message: currentMessage, duration: duration)
                clearRenderedRows(self.lastRenderedRows)
                // \u{001B}[2K clears the current line
                // \r moves the cursor to the beginning of the line
                // We use cyan for the spinner and magenta for the message, matching StreamRenderer
                let ansi = "\u{001B}[2K\r\u{001B}[36m\(frame)\u{001B}[0m \u{001B}[35m\(currentMessage)\u{001B}[0m \u{001B}[2m(esc to cancel, \(duration)s)\u{001B}[0m"
                print(ansi, terminator: "")
                fflush(stdout)
                self.lastRenderedRows = renderedRows
                
                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            }
        }
    }

    /// Updates the spinner message while it is running.
    public func updateMessage(_ newMessage: String) {
        self.message = newMessage
        if let ui, isTaskRunning {
            ui.setSpinner(message: newMessage)
        }
    }
    
    /// Stops the spinner and clears the line.
    public func stop(clearLine: Bool = true) {
        guard isTaskRunning else { return }
        isTaskRunning = false

        if let ui {
            ui.setSpinner(message: nil)
            return
        }

        task?.cancel()
        task = nil
        
        if clearLine {
            clearRenderedRows(lastRenderedRows)
            lastRenderedRows = 0
            fflush(stdout)
        } else {
            print() // Just newline
        }
    }
    
    /// Stops the spinner and replaces it with a completion message.
    public func succeed(with successMessage: String) {
        stop(clearLine: true)
        if let ui {
            ui.appendOutput("\u{001B}[32m✅ \(successMessage)\u{001B}[0m\n")
        } else {
            print("\u{001B}[32m✅ \(successMessage)\u{001B}[0m")
        }
    }
    
    /// Stops the spinner and replaces it with an error message.
    public func fail(with errorMessage: String) {
        stop(clearLine: true)
        if let ui {
            ui.appendOutput("\u{001B}[31m❌ \(errorMessage)\u{001B}[0m\n")
        } else {
            print("\u{001B}[31m❌ \(errorMessage)\u{001B}[0m")
        }
    }

    private func clearRenderedRows(_ rowCount: Int) {
        guard rowCount > 0 else { return }

        print("\r\u{001B}[2K", terminator: "")
        if rowCount > 1 {
            for _ in 1..<rowCount {
                print("\u{001B}[1A\u{001B}[2K", terminator: "")
            }
        }
        print("\r", terminator: "")
    }

    private func renderRowCount(frame: String, message: String, duration: Int) -> Int {
        var terminalWidth = 80
        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0 {
            terminalWidth = max(1, Int(windowSize.ws_col))
        }
        let visibleWidth = frame.count + 1 + message.count + 1 + "(esc to cancel, \(duration)s)".count
        return max(1, (visibleWidth + terminalWidth - 1) / terminalWidth)
    }
}
