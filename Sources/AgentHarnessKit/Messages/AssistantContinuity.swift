import Foundation

/// Same-substrate replay state preserved on assistant turns.
public enum ReplaySubstrate: String, Sendable, Equatable, Codable {
    case openAIChatCompletions
    case responses
    case anthropicMessages
    case geminiContents
}

/// Provider-native assistant-turn continuity preserved alongside semantic fields.
public struct AssistantContinuity: Sendable, Equatable, Codable {
    public let substrate: ReplaySubstrate
    public let payload: JSONValue

    public init(
        substrate: ReplaySubstrate,
        payload: JSONValue
    ) {
        self.substrate = substrate
        self.payload = payload
    }
}

extension AssistantContinuity {
    func droppingServerContinuationAnchor() -> AssistantContinuity {
        switch substrate {
        case .responses:
            serverContinuationAnchorRemoved()
        case .anthropicMessages, .openAIChatCompletions, .geminiContents:
            self
        }
    }

    func removingTerminalFinishTool() -> AssistantContinuity {
        switch substrate {
        case .responses:
            terminalFinishToolRemoved()
        case .anthropicMessages, .openAIChatCompletions, .geminiContents:
            self
        }
    }
}

/// Payload-level implementations for the Responses substrate. The reference keeps these in its
/// Responses provider and round-trips through a typed replay state; core has no provider types,
/// so it edits the JSON payload directly.
private extension AssistantContinuity {
    func serverContinuationAnchorRemoved() -> AssistantContinuity {
        guard case var .object(payload) = payload,
              payload["response_id"] != nil
        else {
            return self
        }
        payload.removeValue(forKey: "response_id")
        return AssistantContinuity(substrate: substrate, payload: .object(payload))
    }

    func terminalFinishToolRemoved() -> AssistantContinuity {
        guard case let .object(payload) = payload,
              case let .array(output) = payload["output"]
        else {
            return self
        }

        let filteredOutput = output.filter { item in
            guard case let .object(object) = item,
                  case let .string(type) = object["type"],
                  type == "function_call",
                  case let .string(name) = object["name"]
            else {
                return true
            }
            return name != "finish"
        }

        guard filteredOutput.count != output.count else {
            return self
        }

        var updatedPayload = payload
        updatedPayload["output"] = .array(filteredOutput)
        return AssistantContinuity(substrate: substrate, payload: .object(updatedPayload))
            .serverContinuationAnchorRemoved()
    }
}
