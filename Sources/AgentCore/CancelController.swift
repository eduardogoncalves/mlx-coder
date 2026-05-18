// Sources/AgentCore/CancelController.swift
// Handles global cancellation signal for model generation.

import Foundation

/// A global controller to manage cancellation of language model generation.
public actor CancelController {
    public static let shared = CancelController()
    
    // Stores a cancellation closure for the current async operation.
    private var cancelCurrentTask: (@Sendable () -> Void)?
    private var listeningTask: Task<Void, Never>?
    private var forceExitOnEscape = false

    /// Handles interrupt messages (e.g. "Interrupted by Esc"). Defaults to
    /// printing to stdout. Set to `{ _ in }` when a TUI renderer owns the
    /// terminal so the raw print cannot corrupt its output.
    public var printHandler: @Sendable (String) -> Void = { print($0) }

    /// Replace the print handler; safe to call from any async context.
    public func setPrintHandler(_ handler: @escaping @Sendable (String) -> Void) {
        printHandler = handler
    }

    private init() {}
    
    /// Set the current operation task and start listening for ESC/Ctrl+C.
    public func setTask(_ task: Task<Void, Error>?, forceExitOnEscape: Bool = false) async {
        let canceler: (@Sendable () -> Void)?
        if let task {
            canceler = { task.cancel() }
        } else {
            canceler = nil
        }
        await updateTrackedCancellation(canceler, forceExitOnEscape: forceExitOnEscape)
    }

    /// Set any typed task as the current cancellable operation.
    public func setTask<T>(_ task: Task<T, Error>?, forceExitOnEscape: Bool = false) async {
        let canceler: (@Sendable () -> Void)?
        if let task {
            canceler = { task.cancel() }
        } else {
            canceler = nil
        }
        await updateTrackedCancellation(canceler, forceExitOnEscape: forceExitOnEscape)
    }

    private func updateTrackedCancellation(_ canceler: (@Sendable () -> Void)?, forceExitOnEscape: Bool) async {
        self.cancelCurrentTask = canceler
        self.forceExitOnEscape = (canceler != nil) ? forceExitOnEscape : false

        // Always cancel any previous listener first.
        // When starting a new task, do not block listener startup on teardown;
        // otherwise cancellation hotkeys can become unresponsive.
        let existingListener = listeningTask
        existingListener?.cancel()
        listeningTask = nil

        if canceler != nil {
            startListening()
            return
        }

        // Only await teardown when disabling listening entirely, so terminal
        // state restoration completes before returning to interactive input.
        if let existingListener {
            await existingListener.value
        }
    }

    /// Temporarily stop listening for ESC/Ctrl+C without clearing the active generation task.
    public func suspendListening() async {
        guard let task = listeningTask else { return }
        task.cancel()
        listeningTask = nil
        // Wait for the listener's defer block to restore terminal state
        // before another input flow changes termios again.
        await task.value
    }

    /// Resume listening only when there is an active generation task.
    public func resumeListeningIfNeeded() {
        guard cancelCurrentTask != nil, listeningTask == nil else { return }
        startListening()
    }
    
    /// Cancel the current task if any
    public func cancel() {
        cancelCurrentTask?()
        cancelCurrentTask = nil
    }
    
    private func startListening() {
        listeningTask = Task.detached {
            var originalTerm = termios()
            tcgetattr(STDIN_FILENO, &originalTerm)
            
            var rawTerm = originalTerm
            // Disable ICANON, ECHO, and ISIG to read char-by-char and catch ESC/Ctrl+C
            rawTerm.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
            // Non-blocking read
            rawTerm.c_cc.16 = 0 // VMIN
            rawTerm.c_cc.17 = 1 // VTIME (0.1s)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawTerm)
            
            defer {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTerm)
            }
            
            while !Task.isCancelled {
                var byte: UInt8 = 0
                let r = read(STDIN_FILENO, &byte, 1)
                
                if r == 1 {
                    if byte == 27 { // ESC
                        // Consume only the ESC sequence tail so the next prompt can keep
                        // legitimate follow-up keypresses (e.g. quick numeric selections).
                        _ = TerminalKeyParser.readEscapeSequence(initialTimeoutMs: 10, extendedTimeoutMs: 40)
                        let shouldForceExit = await self.forceExitOnEscape
                        await self.cancel()
                        if shouldForceExit {
                            let handler = await self.printHandler
                            handler("\nInterrupted by Esc. Exiting...")
                            fflush(stdout)
                            // `exit()` does not run `defer` blocks, so we must
                            // restore terminal state here or the user is left
                            // in a wedged raw-mode shell after Ctrl+C / ESC.
                            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTerm)
                            exit(130)
                        }
                        break
                    } else if byte == 3 { // Ctrl+C
                        // User wants 'Esc' for cancellation, so Ctrl+C should exit the app
                        let handler = await self.printHandler
                        handler("\nInterrupted by Ctrl+C. Exiting...")
                        fflush(stdout)
                        // Restore terminal state before exit(); see note above.
                        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTerm)
                        exit(0)
                    }
                }
                
            }
        }
    }
}
