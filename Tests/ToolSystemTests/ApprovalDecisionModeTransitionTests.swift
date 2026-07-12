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

    func testSwitchToAgentAndAllowFromAutopilotLandsInCodingNotAutopilot() {
        // Entering PLAN from autopilot preserves the .general task type; a
        // plan-block "Switch to AGENT mode and allow" must NOT leave the user in
        // autopilot (agent + general = auto-approve everything). It should
        // collapse to .coding so per-tool approvals stay in effect.
        let transition = approvalDecisionModeTransition(for: .switchToAgentAndAllow, currentTaskType: .general)

        XCTAssertEqual(
            transition,
            ApprovalDecisionModeTransition(workingMode: .agent, taskType: .coding)
        )
    }

    func testNonModeChangingApprovalsDoNotTransitionModes() {
        XCTAssertNil(approvalDecisionModeTransition(for: .allowOnce, currentTaskType: .coding))
        XCTAssertNil(approvalDecisionModeTransition(for: .allowAlwaysForCommand, currentTaskType: .coding))
        XCTAssertNil(approvalDecisionModeTransition(for: .deny(suggestion: nil), currentTaskType: .coding))
    }
}
