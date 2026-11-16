import Foundation

/// A hosted OpenAI Responses tool that does not map to a local `ToolDefinition`.
public enum ResponsesHostedToolDefinition: Sendable, Equatable {
    case fileSearch(vectorStoreIDs: [String], maxNumResults: Int? = nil, filters: JSONValue? = nil)
    case webSearch(
        externalWebAccess: Bool? = nil,
        filters: JSONValue? = nil,
        userLocation: ResponsesApproximateUserLocation? = nil
    )
}

/// An approximate user location for Responses web search.
public struct ResponsesApproximateUserLocation: Sendable, Equatable, Encodable {
    public let country: String?
    public let city: String?
    public let region: String?
    public let timezone: String?
    let type = "approximate"

    public init(
        country: String? = nil,
        city: String? = nil,
        region: String? = nil,
        timezone: String? = nil
    ) {
        self.country = country
        self.city = city
        self.region = region
        self.timezone = timezone
    }
}

extension ResponsesHostedToolDefinition: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, filters
        case vectorStoreIDs = "vector_store_ids"
        case maxNumResults = "max_num_results"
        case externalWebAccess = "external_web_access"
        case userLocation = "user_location"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fileSearch(vectorStoreIDs, maxNumResults, filters):
            try container.encode("file_search", forKey: .type)
            try container.encode(vectorStoreIDs, forKey: .vectorStoreIDs)
            try container.encodeIfPresent(maxNumResults, forKey: .maxNumResults)
            try container.encodeIfPresent(filters, forKey: .filters)
        case let .webSearch(externalWebAccess, filters, userLocation):
            try container.encode("web_search", forKey: .type)
            try container.encodeIfPresent(externalWebAccess, forKey: .externalWebAccess)
            try container.encodeIfPresent(filters, forKey: .filters)
            try container.encodeIfPresent(userLocation, forKey: .userLocation)
        }
    }
}
