// Sources/CLI/Spinner.swift
import Foundation

/// A simple terminal spinner for loading and processing states.
public actor Spinner {
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var isTaskRunning = false
    private var task: Task<Void, Never>?
    private var message: String
    private var startTime: Date?
    
    public init(message: String) {
        self.message = message
    }
    
    /// Starts the spinner animation in a detached task.
    public func start() {
        guard !isTaskRunning else { return }
        isTaskRunning = true

        let f = self.frames
        
        task = Task {
            self.startTime = Date()
            var i = 0
            while !Task.isCancelled {
                let frame = f[i % f.count]
                let duration = Int(Date().timeIntervalSince(self.startTime ?? Date()))
                let currentMessage = self.message
                // \u{001B}[2K clears the entire line
                // \r moves the cursor to the beginning of the line
                // We use cyan for the spinner and magenta for the message, matching StreamRenderer
                let ansi = "\u{001B}[2K\r\u{001B}[36m\(frame)\u{001B}[0m \u{001B}[35m\(currentMessage)\u{001B}[0m \u{001B}[2m(esc to cancel, \(duration)s)\u{001B}[0m"
                print(ansi, terminator: "")
                fflush(stdout)
                
                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            }
        }
    }

    /// Updates the spinner message while it is running.
    public func updateMessage(_ newMessage: String) {
        self.message = newMessage
    }
    
    /// Stops the spinner and clears the line.
    public func stop(clearLine: Bool = true) {
        guard isTaskRunning else { return }
        isTaskRunning = false
        task?.cancel()
        task = nil
        
        if clearLine {
            print("\u{001B}[2K\r", terminator: "")
            fflush(stdout)
        } else {
            print() // Just newline
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
}
