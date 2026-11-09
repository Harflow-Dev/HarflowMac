import Foundation

// MARK: - WireObservation

/// How an additive engine object arrived, kept distinct so an older engine is never confused with a damaged answer.
public enum WireObservation<Value: Equatable & Sendable>: Equatable, Sendable {
    /// The key was not sent: an older engine, or an opted-out specimen.
    case absent
    /// The object was sent and satisfied its contract.
    case present(Value)
    /// The key was sent but the value had the wrong JSON type or lacked a required field.
    case malformed

    /// The decoded value, or nil for both `absent` and `malformed`.
    public var value: Value? {
        if case .present(let value) = self { return value }
        return nil
    }
}

// MARK: - WireFields

/// Strict field readers shared by the additive observation decoders.
enum WireFields {
    /// Strict integer token, exact up to 2^53; the JSON model stores numbers as doubles.
    static func integer(_ value: JSONValue?) -> Int64? {
        guard case .number(let number, let isInteger)? = value, isInteger, number.rounded() == number,
              abs(number) < 9.2e18 else { return nil }
        return Int64(number)
    }

    /// A string-or-null field that must be present: `.some(nil)` means an explicit null.
    static func nullableString(_ object: [String: JSONValue], _ key: String) -> String?? {
        switch object[key] {
        case .some(.null): return .some(nil)
        case .some(.string(let text)): return .some(text)
        default: return nil
        }
    }
}
