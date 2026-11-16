import Foundation
import GRDB
import GRDBGateCore
import AnyLanguageModel

// Compile-time reference so the AnyLanguageModel product is genuinely linked.
let almReference: Any.Type = LanguageModelSession.self

let arguments = CommandLine.arguments

#if os(macOS) || os(Linux)
func spawnSecondProcess(directory: URL) -> [GateCheck] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = ["--second", directory.path]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    do {
        try process.run()
    } catch {
        return [GateCheck(name: "8 second process spawn", status: .fail, detail: "\(error)")]
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let childOK = process.terminationStatus == 0
    return [
        GateCheck(
            name: "8a second process opens same DB, reads parent rows, writes",
            status: childOK ? .pass : .fail,
            detail: "exit=\(process.terminationStatus) output=\(output)"
        ),
    ]
}

func runChild(directory: URL) -> Int32 {
    do {
        let pool = try openGatePool(directory: directory)
        let before = try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1 }
        let sawParent = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT ref FROM message WHERE ref = ?", arguments: [gateSeedRefs[0]])
        } != nil
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO message (ref, sessionID, role, content, tokens, createdAt) VALUES (?, 's-child', 'assistant', 'written by child process', 3, ?)",
                arguments: [gateChildRef, Date()]
            )
        }
        print("CHILD_OK rowsBefore=\(before) sawParentRow=\(sawParent) wrote=\(gateChildRef)")
        return sawParent ? 0 : 1
    } catch {
        print("CHILD_FAIL \(error)")
        return 1
    }
}

if arguments.count == 3, arguments[1] == "--second" {
    exit(runChild(directory: URL(fileURLWithPath: arguments[2], isDirectory: true)))
}
#endif

guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: grdb-gate <directory>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

#if os(macOS) || os(Linux)
let secondProcess: (@Sendable (DatabasePool) -> [GateCheck])? = { _ in
    spawnSecondProcess(directory: directory)
}
#else
let secondProcess: (@Sendable (DatabasePool) -> [GateCheck])? = nil
#endif

let report = runGRDBGate(directory: directory, secondProcess: secondProcess)
for check in report.checks {
    print("\(check.status.rawValue)  \(check.name): \(check.detail)")
}
print("SQLite version: \(report.sqliteVersion ?? "unknown")")
print("Compile options (FTS/THREADSAFE): \(report.compileOptions.joined(separator: " "))")
print("journal_mode: \(report.journalMode ?? "unknown")")
print(report.passed ? "OVERALL: PASS" : "OVERALL: FAIL")
exit(report.passed ? 0 : 1)
