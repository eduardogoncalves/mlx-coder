import XCTest
@testable import MLXCoder

final class SessionStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-coder-sessions-\(UUID().uuidString)", isDirectory: true)
        setenv("MLX_CODER_SESSIONS_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MLX_CODER_SESSIONS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func msg(_ role: Message.Role, _ content: String, origin: Message.Origin = .human) -> Message {
        Message(role: role, content: content, origin: origin)
    }

    func testSaveAndLoadRoundTrip() throws {
        let messages = [
            msg(.user, "add a login screen"),
            msg(.assistant, "done"),
        ]
        let url = SessionStore.save(id: "abc", cwd: "/work", model: "m", messages: messages)
        XCTAssertNotNil(url)

        let loaded = try SessionStore.load(id: "abc")
        XCTAssertEqual(loaded.id, "abc")
        XCTAssertEqual(loaded.cwd, "/work")
        XCTAssertEqual(loaded.model, "m")
        XCTAssertEqual(loaded.messages.count, 2)
        XCTAssertEqual(loaded.title, "add a login screen")
    }

    func testSaveDropsSystemPrompt() throws {
        let messages = [
            msg(.system, "SYSTEM"),
            msg(.user, "hi"),
        ]
        _ = SessionStore.save(id: "s", cwd: "/w", model: "m", messages: messages)
        let loaded = try SessionStore.load(id: "s")
        XCTAssertFalse(loaded.messages.contains { $0.role == .system })
        XCTAssertEqual(loaded.messages.count, 1)
    }

    func testSaveSkipsSessionsWithNoHumanTurn() {
        // Only automated/assistant messages — nothing worth resuming.
        let messages = [
            msg(.user, "steering", origin: .automated),
            msg(.assistant, "ok"),
        ]
        let url = SessionStore.save(id: "empty", cwd: "/w", model: "m", messages: messages)
        XCTAssertNil(url)
        XCTAssertThrowsError(try SessionStore.load(id: "empty"))
    }

    func testListIsScopedByCwdAndSortedByRecency() throws {
        _ = SessionStore.save(id: "a", cwd: "/projA", model: "m", messages: [msg(.user, "first")])
        // Ensure a distinct, later updatedAt for b.
        Thread.sleep(forTimeInterval: 0.01)
        _ = SessionStore.save(id: "b", cwd: "/projA", model: "m", messages: [msg(.user, "second")])
        _ = SessionStore.save(id: "c", cwd: "/projB", model: "m", messages: [msg(.user, "other")])

        let scoped = SessionStore.list(cwd: "/projA")
        XCTAssertEqual(scoped.map(\.id), ["b", "a"])

        let all = SessionStore.list()
        XCTAssertEqual(Set(all.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(SessionStore.mostRecent(cwd: "/projA")?.id, "b")
    }

    func testCreatedAtPreservedAcrossResaves() throws {
        _ = SessionStore.save(id: "keep", cwd: "/w", model: "m", messages: [msg(.user, "one")])
        let firstCreated = try SessionStore.load(id: "keep").createdAt
        Thread.sleep(forTimeInterval: 0.01)
        _ = SessionStore.save(id: "keep", cwd: "/w", model: "m", messages: [msg(.user, "one"), msg(.assistant, "two")])
        let second = try SessionStore.load(id: "keep")
        XCTAssertEqual(second.createdAt.timeIntervalSince1970, firstCreated.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(second.updatedAt, second.createdAt)
    }

    func testRestoreConversationKeepsCurrentSystemPrompt() {
        var history = ConversationHistory(systemPrompt: "FRESH SYSTEM")
        history.addUser("stale should be gone")

        let restored = [
            Message(role: .system, content: "OLD SYSTEM"),
            Message(role: .user, content: "restored user"),
            Message(role: .assistant, content: "restored assistant"),
        ]
        history.restoreConversation(restored)

        XCTAssertEqual(history.messages.first?.role, .system)
        XCTAssertEqual(history.messages.first?.content, "FRESH SYSTEM")
        XCTAssertFalse(history.messages.dropFirst().contains { $0.role == .system })
        XCTAssertEqual(history.messages.count, 3)
        XCTAssertEqual(history.latestUserMessage, "restored user")
    }
}
