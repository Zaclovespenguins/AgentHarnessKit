import Foundation
import SpikeCore

// spike [--only S1,S2] [--checkpoint file] [--resume file] [--serve-mock [port]]
let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

if let i = args.firstIndex(of: "--serve-mock") {
    let port = UInt16(args.indices.contains(i + 1) ? args[i + 1] : "") ?? 8080
    let s = try MockServer(port: port)
    print("mock listening on \(s.baseURL)")
    while true { try await Task.sleep(for: .seconds(3600)) }
}

let provider = try Provider.fromEnvironment()
let checkpoint = URL(fileURLWithPath: value("--checkpoint") ?? "spike-checkpoint.json")
print("provider=\(provider.label)")
let results: [Result]
if let f = value("--resume") {
    results = [await s3Resume(provider, file: URL(fileURLWithPath: f))]
} else {
    results = await runAll(provider, checkpoint: checkpoint, only: Set((value("--only") ?? "").split(separator: ",").map(String.init)))
}
results.forEach { print($0.line) }
exit(results.allSatisfy(\.pass) ? 0 : 1)
