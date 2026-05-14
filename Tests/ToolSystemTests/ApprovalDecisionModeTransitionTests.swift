import XCTest
@testable import MLXCoder

final class ApprovalDecisionModeTransitionTests: XCTestCase {
    func testAllowAllAutopilotTransitionsToAgentGeneral() {
        let transition = approvalDecisionModeTransition(for: .allowAllAutopilot, currentTaskType: .coding)

        XCTAssertEqual(
            transition,
            ApprovalDecisionModeTransition(workingMode: .agent, taskType: .general)
        )
    }

    func testSwitchToAgentAndAllowPreservesCurrentTaskType() {
        let codingTransition = approvalDecisionModeTransition(for: .switchToAgentAndAllow, currentTaskType: .coding)
        let reasoningTransition = approvalDecisionModeTransition(for: .switchToAgentAndAllow, currentTaskType: .reasoning)

        XCTAssertEqual(
            codingTransition,
            ApprovalDecisionModeTransition(workingMode: .agent, taskType: .coding)
        )
        XCTAssertEqual(
            reasoningTransition,
            ApprovalDecisionModeTransition(workingMode: .agent, taskType: .reasoning)
        )
    }

    func testNonModeChangingApprovalsDoNotTransitionModes() {
        XCTAssertNil(approvalDecisionModeTransition(for: .allowOnce, currentTaskType: .coding))
        XCTAssertNil(approvalDecisionModeTransition(for: .allowAlwaysForCommand, currentTaskType: .coding))
        XCTAssertNil(approvalDecisionModeTransition(for: .deny(suggestion: nil), currentTaskType: .coding))
    }
}
