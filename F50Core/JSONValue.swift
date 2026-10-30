import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .number(try container.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue {
        guard case .object(let object) = self else { return .null }
        return object[key] ?? .null
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self, value.isFinite { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var strings: [String]? {
        guard let values = array else { return nil }
        let strings = values.compactMap(\.string)
        return strings.count == values.count ? strings : nil
    }
    var isNull: Bool { self == .null }
}

struct NearbyDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct ClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
