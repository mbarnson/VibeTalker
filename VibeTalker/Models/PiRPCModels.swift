import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated struct PiRPCResponse: Decodable, Equatable, Sendable {
    let id: String?
    let type: String
    let command: String?
    let success: Bool?
    let data: JSONValue?
    let error: String?
}

nonisolated struct PiRPCEvent: Decodable, Equatable, Sendable {
    let type: String
    let id: String?
    let raw: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode([String: JSONValue].self)
        guard case .string(let type)? = raw["type"] else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Pi RPC record has no string type"
            )
        }
        self.type = type
        if case .string(let id)? = raw["id"] {
            self.id = id
        } else {
            self.id = nil
        }
    }
}

nonisolated enum PiRPCCommand: Encodable, Sendable {
    case getState(id: String)
    case setModel(id: String, provider: String, modelID: String)
    case prompt(id: String, message: String)
    case abort(id: String)

    var id: String {
        switch self {
        case .getState(let id),
             .setModel(let id, _, _),
             .prompt(let id, _),
             .abort(let id):
            id
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getState(let id):
            try container.encode(id, forKey: .id)
            try container.encode("get_state", forKey: .type)
        case .setModel(let id, let provider, let modelID):
            try container.encode(id, forKey: .id)
            try container.encode("set_model", forKey: .type)
            try container.encode(provider, forKey: .provider)
            try container.encode(modelID, forKey: .modelID)
        case .prompt(let id, let message):
            try container.encode(id, forKey: .id)
            try container.encode("prompt", forKey: .type)
            try container.encode(message, forKey: .message)
        case .abort(let id):
            try container.encode(id, forKey: .id)
            try container.encode("abort", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case message
        case provider
        case modelID = "modelId"
    }
}
