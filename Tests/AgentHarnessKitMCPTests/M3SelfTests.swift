#if os(macOS) || os(Linux)
    import AgentHarnessKit
    import AgentHarnessKitMCP
    import Foundation
    import Testing

    struct M3SelfTests {
        private func shell(_ script: String, environment: [String: String]? = nil) -> StdioMCPTransport {
            StdioMCPTransport(command: "/bin/sh", arguments: ["-c", script], environment: environment)
        }

        private func nextMessage(_ iterator: inout AsyncThrowingStream<Data, Error>.Iterator) async throws -> String? {
            guard let data = try await iterator.next() else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        @Test func echoRoundTrip() async throws {
            let transport = shell("cat")
            try await transport.connect()
            var iterator = transport.messages().makeAsyncIterator()
            try await transport.send(Data(#"{"id":1}"#.utf8))
            #expect(try await nextMessage(&iterator) == #"{"id":1}"#)
            await transport.disconnect()
        }

        @Test func severalMessagesInOneChunkAreSplitOnNewlines() async throws {
            let transport = shell("printf 'one\\ntwo\\n\\nthree\\n'; cat")
            try await transport.connect()
            var iterator = transport.messages().makeAsyncIterator()
            #expect(try await nextMessage(&iterator) == "one")
            #expect(try await nextMessage(&iterator) == "two")
            #expect(try await nextMessage(&iterator) == "three")
            await transport.disconnect()
        }

        @Test func messageSplitAcrossWritesIsReassembled() async throws {
            let transport = shell("printf 'hel'; sleep 0.3; printf 'lo\\n'; cat")
            try await transport.connect()
            var iterator = transport.messages().makeAsyncIterator()
            #expect(try await nextMessage(&iterator) == "hello")
            await transport.disconnect()
        }

        @Test func environmentIsVisibleToChild() async throws {
            let transport = shell("echo \"$AHK_M3_VALUE\"; cat", environment: ["AHK_M3_VALUE": "value42"])
            try await transport.connect()
            var iterator = transport.messages().makeAsyncIterator()
            #expect(try await nextMessage(&iterator) == "value42")
            await transport.disconnect()
        }

        @Test func sendAfterDisconnectThrowsTransportClosed() async throws {
            let transport = shell("cat")
            try await transport.connect()
            await transport.disconnect()
            await #expect(throws: MCPError.transportClosed) {
                try await transport.send(Data("{}".utf8))
            }
        }

        @Test func sendBeforeConnectThrowsTransportClosed() async throws {
            let transport = shell("cat")
            await #expect(throws: MCPError.transportClosed) {
                try await transport.send(Data("{}".utf8))
            }
        }

        @Test func nonexistentCommandFailsConnect() async throws {
            let transport = StdioMCPTransport(command: "/nonexistent/ahk-m3-binary")
            do {
                try await transport.connect()
                Issue.record("connect should have thrown")
            } catch MCPError.connectionFailed {
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            var iterator = transport.messages().makeAsyncIterator()
            #expect(try await iterator.next() == nil)
        }

        @Test func messagesStreamFinishesAfterDisconnect() async throws {
            let transport = shell("cat")
            try await transport.connect()
            var iterator = transport.messages().makeAsyncIterator()
            await transport.disconnect()
            #expect(try await iterator.next() == nil)
        }

        @Test func disconnectTwiceIsSafe() async throws {
            let transport = shell("cat")
            try await transport.connect()
            await transport.disconnect()
            await transport.disconnect()
        }

        @Test func disconnectKillsChildThatIgnoresStdinClose() async throws {
            let transport = shell("trap '' TERM; while :; do sleep 1; done")
            try await transport.connect()
            let start = ContinuousClock.now
            await transport.disconnect()
            #expect(ContinuousClock.now - start < .seconds(15))
        }
    }
#endif
