// Sources/CLI/Spinner.swift
import Foundation
import Darwin

/// A simple terminal spinner for loading and processing states.
///
/// `start`/`stop`/`updateMessage` are synchronous and serialized under a
/// lock (not actor-isolated) so `stop(clearLine:)` can run to completion —
/// including its clear-line write — before the caller returns. Callers
/// immediately print their own content right after stopping the spinner
/// (e.g. `LegacyTerminalFrontend.emit` prints a tool-call box or assistant
/// text right after `stopSpinnerImmediately()`). When `stop` was an actor
/// method invoked via a fire-and-forget `Task { await spinner.stop(...) }`,
/// that stop could be scheduled but not yet run by the time the caller's
/// own print landed, so the ticking animation loop (an independent Task
/// racing on the same stdout) could write one more frame — or the delayed
/// stop's own clear-line write could land — after the caller's content was
/// already on screen, wiping or corrupting it. Serializing every write
/// (ticks, stop's clear, and start/update calls) behind one lock removes
/// that race: `stop()` now always finishes clearing before it returns.
public final class Spinner: @unchecked Sendable {
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let lock = NSLock()
    private var isTaskRunning = false
    private var task: Task<Void, Never>?
    private var message: String
    private var lastRenderedRows = 0

    public init(message: String) {
        self.message = message
    }

    /// Starts the spinner animation in a background task.
    public func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            if isTaskRunning { return true }
            isTaskRunning = true
            return false
        }
        guard !alreadyRunning else { return }

        let f = frames
        task = Task { [weak self] in
            let startTime = Date()
            var i = 0
            while !Task.isCancelled {
                guard let self else { return }
                let stillRunning = self.lock.withLock { () -> Bool in
                    guard self.isTaskRunning else { return false }
                    let frame = f[i % f.count]
                    let duration = Int(Date().timeIntervalSince(startTime))
                    let currentMessage = self.message
                    let renderedRows = self.renderRowCount(frame: frame, message: currentMessage, duration: duration)
                    self.clearRenderedRowsLocked(self.lastRenderedRows)
                    // \u{001B}[2K clears the current line
                    // \r moves the cursor to the beginning of the line
                    // We use cyan for the spinner and magenta for the message, matching StreamRenderer
                    let ansi = "\u{001B}[2K\r\u{001B}[36m\(frame)\u{001B}[0m \u{001B}[35m\(currentMessage)\u{001B}[0m \u{001B}[2m(esc to cancel, \(duration)s)\u{001B}[0m"
                    print(ansi, terminator: "")
                    fflush(stdout)
                    self.lastRenderedRows = renderedRows
                    return true
                }
                guard stillRunning else { return }

                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            }
        }
    }

    /// Updates the spinner message while it is running.
    public func updateMessage(_ newMessage: String) {
        lock.withLock { message = newMessage }
    }

    /// Stops the spinner and clears the line. Synchronous: the clear-line
    /// write (if any) has completed by the time this returns.
    public func stop(clearLine: Bool = true) {
        lock.withLock {
            guard isTaskRunning else { return }
            isTaskRunning = false
            task?.cancel()
            task = nil

            if clearLine {
                clearRenderedRowsLocked(lastRenderedRows)
                lastRenderedRows = 0
                fflush(stdout)
            } else {
                print() // Just newline
            }
        }
    }

    /// Stops the spinner and replaces it with a completion message.
    public func succeed(with successMessage: String) {
        stop(clearLine: true)
        print("\u{001B}[32m✅ \(successMessage)\u{001B}[0m")
    }

    /// Stops the spinner and replaces it with an error message.
    public func fail(with errorMessage: String) {
        stop(clearLine: true)
        print("\u{001B}[31m❌ \(errorMessage)\u{001B}[0m")
    }

    /// Must be called with `lock` held.
    private func clearRenderedRowsLocked(_ rowCount: Int) {
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
