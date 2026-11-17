import Foundation

/// A stream element for the agent loop: a public delta, or the finished turn's replay state.
package enum RunStreamElement {
    case delta(StreamDelta)
    case finalizedContinuity(AssistantContinuity)
}
