import AgentHarnessKit
import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum ErrorMapping {
    /// `CancellationError` and `AgentError` pass through unchanged; everything else becomes
    /// `AgentError.llmError(TransportError)`.
    static func agentError(from error: any Error, provider: ProviderIdentifier) -> any Error {
        if error is CancellationError {
            return error
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
                ? CancellationError()
                : AgentError.llmError(TransportError.networkError(urlError))
        }
        if let agentError = error as? AgentError {
            return agentError
        }
        if let transportError = error as? HTTPTransportError {
            return AgentError.llmError(map(transportError, provider: provider))
        }
        if error is DecodingError {
            return AgentError.llmError(.decodingFailed(description: String(describing: error)))
        }
        if error is EncodingError {
            return AgentError.llmError(.encodingFailed(description: String(describing: error)))
        }
        return AgentError.llmError(.other(String(describing: error)))
    }

    private static func map(_ error: HTTPTransportError, provider: ProviderIdentifier) -> TransportError {
        let bodyText = error.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        switch error.kind {
        case .httpError:
            // ALM's validate step always attaches the response; without it, keep the detail as `.other`.
            guard let statusCode = error.response?.status.code else {
                return .other(String(describing: error))
            }
            if statusCode == 429 {
                return .rateLimited(retryAfter: nil)
            }
            return .httpError(statusCode: statusCode, body: bodyText)
        case .providerError:
            return .providerError(provider: provider, code: nil, message: bodyText)
        case .decodingError:
            return .decodingFailed(description: String(describing: error))
        case .invalidResponse:
            return .invalidResponse
        default:
            return .other(String(describing: error))
        }
    }
}
