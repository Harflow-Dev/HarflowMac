import Foundation

/// Any JSON value, for fields the app shows but never switches on (enforcement blocks, event
/// extras, notes). Decoding never fails on shape, only on invalid JSON.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 { return Int(value) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Compact, key-sorted JSON — how the Raw events tab and the inspector render a value.
    public func rendered(pretty: Bool = false) -> String {
        let object = foundationObject
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else { return "\(self)" }
        return text
    }

    var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

extension JSONValue {
    /// Parses one JSON text. nil for anything that is not valid JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
