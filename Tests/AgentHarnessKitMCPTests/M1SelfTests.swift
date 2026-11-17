import AgentHarnessKit
import AgentHarnessKitMCP
import Foundation
import Testing

struct M1SelfTests {
    private func decodeContent(_ json: String) throws -> MCPContent {
        try JSONDecoder().decode(MCPContent.self, from: Data(json.utf8))
    }

    private func decodeResult(_ json: String) throws -> MCPCallResult {
        try JSONDecoder().decode(MCPCallResult.self, from: Data(json.utf8))
    }

    @Test func decodesTextContent() throws {
        #expect(try decodeContent(#"{"type":"text","text":"hi"}"#) == .text("hi"))
    }

    @Test func decodesImageAndAudioContent() throws {
        let b64 = Data("abc".utf8).base64EncodedString()
        #expect(try decodeContent(#"{"type":"image","data":"\#(b64)","mimeType":"image/png"}"#)
            == .image(data: Data("abc".utf8), mimeType: "image/png"))
        #expect(try decodeContent(#"{"type":"audio","data":"\#(b64)","mimeType":"audio/wav"}"#)
            == .audio(data: Data("abc".utf8), mimeType: "audio/wav"))
    }

    @Test func invalidBase64Throws() {
        #expect(throws: DecodingError.self) {
            try decodeContent(#"{"type":"image","data":"!!!","mimeType":"image/png"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeContent(#"{"type":"resource","resource":{"uri":"u","blob":"!!!"}}"#)
        }
    }

    @Test func unknownTypeThrows() {
        #expect(throws: DecodingError.self) {
            try decodeContent(#"{"type":"hologram"}"#)
        }
    }

    @Test func decodesResourceLinkAndEmbeddedResource() throws {
        #expect(try decodeContent(#"{"type":"resource_link","uri":"file:///a","name":"a"}"#)
            == .resourceLink(uri: "file:///a", name: "a"))
        #expect(try decodeContent(#"{"type":"resource","resource":{"uri":"u","mimeType":"text/plain","text":"body"}}"#)
            == .embeddedResource(uri: "u", mimeType: "text/plain", content: .text("body")))
    }

    @Test func embeddedResourcePrefersTextOverBlobAndTreatsNonStringTextAsAbsent() throws {
        let b64 = Data("bin".utf8).base64EncodedString()
        #expect(try decodeContent(#"{"type":"resource","resource":{"uri":"u","text":"t","blob":"\#(b64)"}}"#)
            == .embeddedResource(uri: "u", mimeType: nil, content: .text("t")))
        #expect(try decodeContent(#"{"type":"resource","resource":{"uri":"u","text":5,"blob":"\#(b64)"}}"#)
            == .embeddedResource(uri: "u", mimeType: nil, content: .blob(Data("bin".utf8))))
    }

    @Test func isErrorDefaultsToFalse() throws {
        let result = try decodeResult(#"{"content":[{"type":"text","text":"ok"}]}"#)
        #expect(result.isError == false)
        #expect(result.structuredContent == nil)
        #expect(result.toToolResult() == ToolResult(content: "ok", isError: false))
    }

    @Test func toolResultFormatsEachContentType() throws {
        let b64 = Data("x".utf8).base64EncodedString()
        let result = try decodeResult("""
        {"content":[
          {"type":"text","text":"hello"},
          {"type":"image","data":"\(b64)","mimeType":"image/png"},
          {"type":"audio","data":"\(b64)","mimeType":"audio/wav"},
          {"type":"resource_link","uri":"file:///a","name":"a"},
          {"type":"resource","resource":{"uri":"u","blob":"\(b64)"}}
        ],"isError":true}
        """)
        #expect(result.isError)
        #expect(result.toToolResult() == ToolResult(
            content: "hello\n[Image: image/png]\n[Audio: audio/wav]\n[a](file:///a)\n[Embedded resource]",
            isError: true
        ))
    }

    @Test func structuredContentIsPreferredOverContent() throws {
        let result = try decodeResult(#"{"content":[{"type":"text","text":"ignored"}],"structuredContent":{"a":1},"isError":false}"#)
        #expect(result.structuredContent != nil)
        #expect(try result.toToolResult().content == String(decoding: #require(result.structuredContent), as: UTF8.self))
        #expect(result.toToolResult().content.contains("\"a\""))
        #expect(!result.toToolResult().content.contains("ignored"))
    }
}
