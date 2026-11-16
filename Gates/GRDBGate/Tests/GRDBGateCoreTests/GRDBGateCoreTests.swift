import Foundation
import Testing
import AnyLanguageModel
import GRDBGateCore

@Suite("GRDB gate core")
struct GRDBGateCoreTests {
    @Test("pool, migration, FTS5, read/write and WAL run in an explicit directory")
    func gateRunsInExplicitDirectory() throws {
        // Test-only directory choice; the library itself never assumes TMPDIR.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = runGRDBGate(directory: directory)

        #expect(report.checks.filter { $0.status == .fail }.isEmpty, "\(report.checks)")
        #expect(report.checks.count == 8)
        #expect(report.checks.last?.status == .notApplicable)
        #expect(report.journalMode?.lowercased() == "wal")
        #expect(report.sqliteVersion != nil)
        #expect(report.compileOptions.contains { $0.contains("ENABLE_FTS5") })
    }

    @Test("AnyLanguageModel links alongside GRDB")
    func almLinks() {
        let reference: Any.Type = LanguageModelSession.self
        #expect(String(describing: reference).contains("LanguageModelSession"))
    }
}
