import Foundation
import Testing
@testable import SpikeCore

@Test func allScenariosPassAgainstMock() async throws {
    let p = try Provider.fromEnvironment()
    let ckpt = FileManager.default.temporaryDirectory.appendingPathComponent("spike-test-ckpt.json")
    for r in await runAll(p, checkpoint: ckpt) { #expect(r.pass, "\(r.line)") }
}
