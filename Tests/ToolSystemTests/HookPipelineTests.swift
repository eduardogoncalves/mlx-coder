import XCTest
@testable import MLXCoder

private actor HookEventCollector {
    private(set) var events: [String] = []

    func append(_ entry: String) {
        events.append(entry)
    }

    func all() -> [String] {
        events
    }
}

private struct RecordingHook: AgentHook {
    let name: String
    let collector: HookEventCollector

    func handle(event: AgentHookEvent) async {
        switch event {
        case .permissionRequest(let toolName, let isPlanMode):
            await collector.append("permission:\(toolName):\(isPlanMode)")
        case .preToolUse(let toolName, _):
            await collector.append("pre:\(toolName)")
        case .postToolUse(let toolName, let isError, _):
            await collector.append("post:\(toolName):\(isError)")
        case .compression(let toolName, let before, let after, let usedFallback):
            await collector.append("compression:\(toolName):\(before):\(after):\(usedFallback)")
        }
    }
}

final class HookPipelineTests: XCTestCase {
    func testHookPipelineDispatchesEventsInOrder() async {
        let pipeline = HookPipeline()
        let collector = HookEventCollector()
        await pipeline.register(RecordingHook(name: "recorder", collector: collector))

        await pipeline.emit(.permissionRequest(toolName: "write_file", isPlanMode: true))
        await pipeline.emit(.preToolUse(toolName: "write_file", argumentsPreview: "{}"))
        await pipeline.emit(.postToolUse(toolName: "write_file", isError: false, resultPreview: "ok"))

        let events = await collector.all()
        XCTAssertEqual(events, [
            "permission:write_file:true",
            "pre:write_file",
            "post:write_file:false"
        ])
    }
}
