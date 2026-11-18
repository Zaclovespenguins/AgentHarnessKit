import Foundation
#if canImport(Glibc)
    import Glibc
#endif

#if os(macOS) || os(Linux)
    /// An MCP transport that communicates over a child process's stdin/stdout, one JSON message per line.
    ///
    /// @unchecked Sendable justification: Process and Pipe are not Sendable.
    /// Mutable state (process, stdinPipe, stdoutHandle, stdoutChunkContinuation,
    /// stdoutReaderTask) follows a strict lifecycle: written once in connect(),
    /// read in send()/disconnect(), cleared in disconnect().
    /// stream and continuation are immutable let properties constructed in init.
    /// The owning MCPClient actor serializes all access through the MCPTransport protocol.
    public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
        private let command: String
        private let arguments: [String]
        private let environment: [String: String]?
        private let workingDirectory: URL?
        private let stream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation

        private var process: Process?
        private var stdinPipe: Pipe?
        private var stdoutHandle: FileHandle?
        private var stdoutChunkContinuation: AsyncStream<Data>.Continuation?
        private var stdoutReaderTask: Task<Void, Never>?

        public init(
            command: String,
            arguments: [String] = [],
            environment: [String: String]? = nil,
            workingDirectory: URL? = nil
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            self.stream = stream
            self.continuation = continuation
        }

        public func connect() async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.finish()
                throw MCPError.connectionFailed("Failed to start process '\(command)': \(error)")
            }

            // A child that exits before we write would otherwise deliver SIGPIPE and kill this process.
            signal(SIGPIPE, SIG_IGN)

            // Drain stderr so a chatty child cannot block on a full pipe; its content is discarded.
            stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                if fileHandle.availableData.isEmpty {
                    fileHandle.readabilityHandler = nil
                }
            }

            self.process = process
            self.stdinPipe = stdinPipe

            let handle = stdoutPipe.fileHandleForReading
            stdoutHandle = handle
            let (chunks, chunkContinuation) = AsyncStream<Data>.makeStream()
            stdoutChunkContinuation = chunkContinuation
            stdoutReaderTask = makeStdoutReaderTask(chunks: chunks)

            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else {
                    fileHandle.readabilityHandler = nil
                    chunkContinuation.finish()
                    return
                }
                chunkContinuation.yield(chunk)
            }
        }

        public func disconnect() async {
            // Take ownership of the child first so a second call is a no-op.
            let process = process
            self.process = nil
            let stdinPipe = stdinPipe
            self.stdinPipe = nil

            stdoutHandle?.readabilityHandler = nil
            stdoutHandle = nil
            stdoutChunkContinuation?.finish()
            stdoutChunkContinuation = nil
            stdoutReaderTask?.cancel()
            stdoutReaderTask = nil
            continuation.finish()

            guard let process, process.isRunning else { return }

            try? stdinPipe?.fileHandleForWriting.close()

            if await Self.waitForExit(process, within: .seconds(2)) {
                return
            }
            process.terminate()
            if await Self.waitForExit(process, within: .seconds(3)) {
                return
            }
            kill(process.processIdentifier, SIGKILL)
            // Poll rather than waitUntilExit(), which would block a cooperative-pool thread.
            _ = await Self.waitForExit(process, within: nil)
        }

        /// Returns true once the process has exited, or false if `limit` elapses first (nil means no limit).
        private static func waitForExit(_ process: Process, within limit: Duration?) async -> Bool {
            let deadline = limit.map { ContinuousClock.now.advanced(by: $0) }
            while process.isRunning {
                if let deadline, ContinuousClock.now >= deadline {
                    return false
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }

        public func send(_ data: Data) async throws {
            guard let stdinPipe else { throw MCPError.transportClosed }
            var framed = data
            framed.append(UInt8(ascii: "\n"))
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: framed)
            } catch {
                throw MCPError.connectionFailed("Write failed: \(error)")
            }
        }

        public nonisolated func messages() -> AsyncThrowingStream<Data, Error> {
            stream
        }

        private func makeStdoutReaderTask(chunks: AsyncStream<Data>) -> Task<Void, Never> {
            let continuation = continuation
            return Task {
                var buffer = Data()
                let newline = UInt8(ascii: "\n")

                for await chunk in chunks {
                    buffer.append(chunk)
                    var lineStart = buffer.startIndex
                    while let newlineIndex = buffer[lineStart...].firstIndex(of: newline) {
                        if newlineIndex > lineStart {
                            continuation.yield(Data(buffer[lineStart ..< newlineIndex]))
                        }
                        lineStart = buffer.index(after: newlineIndex)
                    }
                    buffer.removeSubrange(buffer.startIndex ..< lineStart)
                }

                // A final line without a trailing newline is still a message.
                if !buffer.isEmpty {
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
        }
    }
#endif
