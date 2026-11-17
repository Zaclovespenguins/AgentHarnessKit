import AgentHarnessKit
import AnyLanguageModel
import Foundation

/// A tool declared to ALM so the provider sees its schema. The harness executes tools itself,
/// so `call` always throws.
struct DeclaredTool: AnyLanguageModel.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema

    func call(arguments _: GeneratedContent) async throws -> String {
        throw AgentError.llmError(.other("DeclaredTool '\(name)' must never be executed by AnyLanguageModel"))
    }
}

enum ToolBridging {
    /// Converts a core JSON Schema into ALM's `GenerationSchema` by decoding its standard JSON form.
    static func generationSchema(from schema: JSONSchema) throws -> GenerationSchema {
        let generation: GenerationSchema
        do {
            let json = try JSONEncoder().encode(schema)
            generation = try JSONDecoder().decode(GenerationSchema.self, from: json)
        } catch {
            throw AgentError.llmError(.encodingFailed(description: "Tool schema could not be converted: \(error)"))
        }
        // ALM's decoder accepts more than it preserves, so check the fields the provider relies on.
        let converted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(generation))
        try verifyFields(of: schema, in: converted)
        return generation
    }

    static func almTools(from definitions: [ToolDefinition]) throws -> [any AnyLanguageModel.Tool] {
        var tools: [any AnyLanguageModel.Tool] = []
        for definition in definitions {
            try tools.append(DeclaredTool(
                name: definition.name,
                description: definition.description,
                parameters: generationSchema(from: definition.parametersSchema)
            ))
        }
        return tools
    }

    /// Checks that each object's property names and `required` list survived conversion, recursing
    /// into properties and array items.
    private static func verifyFields(of schema: JSONSchema, in json: Any) throws {
        switch schema {
        case let .object(properties, required, _):
            guard let dict = json as? [String: Any],
                  let convertedProperties = dict["properties"] as? [String: Any],
                  Set(convertedProperties.keys) == Set(properties.keys),
                  Set((dict["required"] as? [String]) ?? []) == Set(required)
            else {
                throw mismatch()
            }
            for (name, child) in properties {
                if let childJSON = convertedProperties[name] {
                    try verifyFields(of: child, in: childJSON)
                }
            }
        case let .array(items, _):
            if let dict = json as? [String: Any], let itemsJSON = dict["items"] {
                try verifyFields(of: items, in: itemsJSON)
            }
        default:
            break
        }
    }

    private static func mismatch() -> AgentError {
        AgentError.llmError(.encodingFailed(description: "Tool schema fields were not preserved during conversion"))
    }
}
