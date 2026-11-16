@testable import AgentHarnessKit
import Foundation
import Testing

struct AgentErrorTests {
    @Test
    func feedbackMessageContainsRelevantInfo() {
        let error1 = AgentError.toolNotFound(name: "myTool")
        #expect(error1.feedbackMessage.contains("myTool"))
        #expect(error1.feedbackMessage.contains("Error"))

        let error2 = AgentError.toolDecodingFailed(tool: "parser", message: "missing field")
        #expect(error2.feedbackMessage.contains("parser"))
        #expect(error2.feedbackMessage.contains("missing field"))

        let error3 = AgentError.toolTimeout(tool: "slowTool")
        #expect(error3.feedbackMessage.contains("slowTool"))
        #expect(error3.feedbackMessage.contains("timed out"))

        let error4 = AgentError.toolExecutionFailed(tool: "crasher", message: "null pointer")
        #expect(error4.feedbackMessage.contains("crasher"))
        #expect(error4.feedbackMessage.contains("null pointer"))

        let error5 = AgentError.toolEncodingFailed(tool: "encoder", message: "invalid utf8")
        #expect(error5.feedbackMessage.contains("encoder"))
        #expect(error5.feedbackMessage.contains("invalid utf8"))

        let error6 = AgentError.finishDecodingFailed(message: "unexpected token")
        #expect(error6.feedbackMessage.contains("unexpected token"))

        let error7 = AgentError.llmError(.other("rate limited"))
        #expect(error7.feedbackMessage.contains("rate limited"))

        let error8 = AgentError.llmError(.streamFailed(.malformedStream(
            reason: .toolCallDeltaWithoutStart(index: 3),
            diagnostics: .empty
        )))
        #expect(error8.feedbackMessage.contains("3"))

        let error9 = AgentError.llmError(.streamFailed(.malformedStream(
            reason: .missingToolCallId(index: 5),
            diagnostics: .empty
        )))
        #expect(error9.feedbackMessage.contains("5"))
        #expect(error9.feedbackMessage.contains("ID"))

        let error10 = AgentError.llmError(.streamFailed(.malformedStream(
            reason: .missingToolCallName(index: 7),
            diagnostics: .empty
        )))
        #expect(error10.feedbackMessage.contains("7"))
        #expect(error10.feedbackMessage.contains("name"))

        let error11 = AgentError.missingContextWindowSize
        #expect(error11.feedbackMessage.contains("Context management"))
        #expect(error11.feedbackMessage.contains("contextWindowSize"))
    }
}
