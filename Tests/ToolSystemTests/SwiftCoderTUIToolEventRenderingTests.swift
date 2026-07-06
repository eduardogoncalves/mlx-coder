import XCTest
import SwiftCoderTUI
@testable import MLXCoder

/// Captures everything the renderer writes so tests can assert on the
/// terminal byte stream without a TTY.
private final class CaptureTerminal: Terminal, @unchecked Sendable {
    let rows = 40
    let cols = 120

    private let lock = NSLock()
    private var buffer = ""

    var output: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func write(_ s: String) {
        lock.lock(); buffer += s; lock.unlock()
    }

    func moveTo(row: Int, col: Int) {}
    func clearLine() {}
    func clearToEndOfLine() {}
    func clearScreen() {}
    func hideCursor() {}
    func showCursor() {}
    func setupRawMode(title: String) {}
    func restoreMode() {}
    func setTitle(_ title: String) {}
    func updateSize() {}
    func beginFrame() {}
    func endFrame() {}
    func setBracketedPaste(enabled: Bool) {}
}

final class SwiftCoderTUIToolEventRenderingTests: XCTestCase {
    func testToolCallEventsRenderDuringGenerationLifecycle() async throws {
        let terminal = CaptureTerminal()
        let config = SwiftCoderTUIAppConfigBuilder.build(version: "test", models: [], defaultModelIndex: 0)
        let renderer = Renderer(config: config, terminal: terminal)
        let frontend = SwiftCoderTUIFrontend(renderer: renderer, appConfig: config)

        // Mirror the real AgentLoop event order for a tool-call turn:
        // generation streams text, ends, then tools execute and report.
        frontend.emit(.tokenProcessingActivity(.started))
        frontend.emit(.generationActivity(.started))
        frontend.emit(.assistantTextChunk("Creating the solution now.\n"))
        frontend.emit(.generationActivity(.ended))
        frontend.emit(.toolCallStarted(ToolCallSnapshot(
            name: "bash",
            arguments: ["command": "dotnet new sln -n AgoraMT"]
        )))
        frontend.emit(.toolCallResult(ToolResultSnapshot(
            toolName: "bash",
            isError: false,
            content: "The template \"Solution File\" was created successfully."
        )))

        try await waitUntil(
            "tool call and result rendered",
            { terminal.output.contains("dotnet new sln -n AgoraMT") && terminal.output.contains("created successfully") }
        )
    }

    func testToolCallEventsRenderWhileGenerationStillActive() async throws {
        let terminal = CaptureTerminal()
        let config = SwiftCoderTUIAppConfigBuilder.build(version: "test", models: [], defaultModelIndex: 0)
        let renderer = Renderer(config: config, terminal: terminal)
        let frontend = SwiftCoderTUIFrontend(renderer: renderer, appConfig: config)

        // Tool events arriving while the spinner is still active must not be dropped.
        frontend.emit(.tokenProcessingActivity(.started))
        frontend.emit(.generationActivity(.started))
        frontend.emit(.toolCallStarted(ToolCallSnapshot(name: "list_dir", arguments: ["path": "."])))
        frontend.emit(.toolCallResult(ToolResultSnapshot(toolName: "list_dir", isError: false, content: "AgoraMT.sln")))

        try await waitUntil(
            "tool call rendered mid-generation",
            { terminal.output.contains("list_dir") && terminal.output.contains("AgoraMT.sln") }
        )
    }

    private func waitUntil(
        _ what: String,
        _ condition: @escaping () -> Bool,
        timeoutMs: Int = 3000
    ) async throws {
        for _ in 0..<(timeoutMs / 20) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for: \(what)")
    }
}
