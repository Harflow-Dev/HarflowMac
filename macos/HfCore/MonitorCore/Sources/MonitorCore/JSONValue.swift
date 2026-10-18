import CoreFoundation
import Foundation

/// Any JSON value, for fields the app shows but never switches on (enforcement blocks, event
/// extras, notes). Decoding never fails on shape, only on invalid JSON.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double, isInteger: Bool = true)
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
        if case .number(let value, _) = self, value.rounded() == value, abs(value) < 1e15 { return Int(value) }
        return nil
    }

    /// Integer JSON token, distinct from a mathematically integral floating-point token.
    public var wireIntegerValue: Int? {
        guard case .number(_, let isInteger) = self, isInteger else { return nil }
        return intValue
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let first), .string(let second)): return first == second
        case (.number(let first, _), .number(let second, _)): return first == second
        case (.bool(let first), .bool(let second)): return first == second
        case (.null, .null): return true
        case (.array(let first), .array(let second)): return first == second
        case (.object(let first), .object(let second)): return first == second
        default: return false
        }
    }

    public var doubleValue: Double? {
        if case .number(let value, _) = self { return value }
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
        case .number(let value, _): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
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
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return fromFoundation(value)
    }

    private static func fromFoundation(_ value: Any) -> JSONValue? {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            return .number(number.doubleValue, isInteger: type != "d" && type != "f")
        }
        if let text = value as? String { return .string(text) }
        if let values = value as? [Any] {
            let converted = values.compactMap(fromFoundation)
            return converted.count == values.count ? .array(converted) : nil
        }
        if let values = value as? [String: Any] {
            let converted = values.compactMapValues(fromFoundation)
            return converted.count == values.count ? .object(converted) : nil
        }
        return nil
    }
}
