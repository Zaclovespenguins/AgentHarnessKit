import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct SupportSmokeTests {
    @Test func mockServerServesAndRecords() async throws {
        let server = MockHTTPServer { request in
            (200, ["Content-Type": "application/json"], request.body)
        }
        var request = URLRequest(url: server.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"a\":1}".utf8)
        request.setValue("yes", forHTTPHeaderField: "X-Test")
        let (data, response) = try await server.session.data(for: request)
        #expect(String(decoding: data, as: UTF8.self) == "{\"a\":1}")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.header("x-test") == "yes")
        #expect(server.requests.first?.method == "POST")
    }
}
