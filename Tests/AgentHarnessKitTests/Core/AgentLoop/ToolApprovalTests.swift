@testable import AgentHarnessKit
import Foundation
import Testing

// MARK: - Policy Unit Tests

struct ToolApprovalPolicyTests {
    @Test
    func policyNoneNeverRequiresApproval() {
        let policy = ToolApprovalPolicy.none
        #expect(!policy.requiresApproval(toolName: "echo", allowlist: []))
        #expect(!policy.requiresApproval(toolName: "search", allowlist: []))
    }

    @Test
    func policyAllToolsRequiresApproval() {
        let policy = ToolApprovalPolicy.allTools
        #expect(policy.requiresApproval(toolName: "echo", allowlist: []))
        #expect(policy.requiresApproval(toolName: "search", allowlist: []))
    }

    @Test
    func policySpecificOnlyMatchesNamed() {
        let policy = ToolApprovalPolicy.tools(["echo"])
        #expect(policy.requiresApproval(toolName: "echo", allowlist: []))
        #expect(!policy.requiresApproval(toolName: "search", allowlist: []))
    }

    @Test
    func allowlistOverridesPolicy() {
        let policy = ToolApprovalPolicy.allTools
        #expect(!policy.requiresApproval(toolName: "echo", allowlist: ["echo"]))
    }
}
