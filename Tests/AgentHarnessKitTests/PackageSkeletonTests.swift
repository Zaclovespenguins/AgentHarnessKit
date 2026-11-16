import Testing

@testable import AgentHarnessKit

/// Trivial smoke test so `swift test` exercises the skeleton on every platform.
@Test func coreTargetIsReachable() {
    _ = AgentHarnessKitModule.self
}
