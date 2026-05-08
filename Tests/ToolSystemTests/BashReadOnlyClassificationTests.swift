import XCTest
@testable import MLXCoder

final class BashReadOnlyClassificationTests: XCTestCase {
    func testAcceptsReadOnlyGitStatus() {
        XCTAssertTrue(AgentLoop.isReadOnlyBashCommand("git status"))
    }

    func testRejectsMutatingGitCommand() {
        XCTAssertFalse(AgentLoop.isReadOnlyBashCommand("git add ."))
    }

    func testRejectsShellChainingEvenForReadOnlyCommands() {
        XCTAssertFalse(AgentLoop.isReadOnlyBashCommand("git status && pwd"))
    }
}
