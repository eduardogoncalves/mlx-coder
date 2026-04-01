// Sources/AgentCore/CancelController.swift
// Handles global cancellation signal for model generation.

import Foundation

/// A global controller to manage cancellation of language model generation.
public actor CancelController {
    public static let shared = CancelController()
    
    // We store the current generation task
    private var generationTask: Task<Void, Error>?
    private var listeningTask: Task<Void, Never>?
    
    private init() {}
    
    /// Set the current generation task and start listening for ESC
    public func setTask(_ task: Task<Void, Error>?) async {
        self.generationTask = task

        // Always cancel any previous listener first.
        // When starting a new task, do not block listener startup on teardown;
        // otherwise cancellation hotkeys can become unresponsive.
        let existingListener = listeningTask
        existingListener?.cancel()
        listeningTask = nil

        if task != nil {
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
        guard generationTask != nil, listeningTask == nil else { return }
        startListening()
    }
    
    /// Cancel the current task if any
    public func cancel() {
        generationTask?.cancel()
        generationTask = nil
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
                        await self.cancel()
                        break
                    } else if byte == 3 { // Ctrl+C
                        // User wants 'Esc' for cancellation, so Ctrl+C should exit the app
                        print("\nInterrupted by Ctrl+C. Exiting...")
                        fflush(stdout)
                        exit(0)
                    }
                }
                
            }
        }
    }
}
