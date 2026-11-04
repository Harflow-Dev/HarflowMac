import Foundation

// MARK: - TaskEventRecord

/// A normalized record with independent historical envelope provenance and opaque payload.
/// Missing payload fields and loss markers never acquire the legacy parser's presentation defaults.
public struct TaskEventRecord: Equatable, Sendable {
    public let seq: Int
    public let kind: String
    /// The original nullable source observation string; it need not parse as an ISO date.
    public let observedAt: String?
    public let truncated: Bool?
    public let oversized: Bool?
    public let bytes: Int?
    public let raw: [String: JSONValue]

    /// Validates known metadata without interpreting kind-specific optional payloads.
    public init?(raw: [String: JSONValue]) {
        guard WireEnvelope.validate(raw, contract: .events) == nil,
              let seq = raw["seq"]?.wireIntegerValue, seq >= 0,
              let kind = raw["kind"]?.stringValue,
              raw["observed_at"] == .null || raw["observed_at"]?.stringValue != nil,
              (raw["observed_at"]?.stringValue?.unicodeScalars.count ?? 0) <= 128,
              raw["truncated"] == nil || raw["truncated"]?.boolValue != nil,
              raw["oversized"] == nil || raw["oversized"]?.boolValue != nil,
              raw["bytes"] == nil || raw["bytes"]?.wireIntegerValue.map({ $0 >= 0 }) == true,
              Self.fitsSerializationLowerBound(raw) else { return nil }
        self.seq = seq
        self.kind = kind
        observedAt = raw["observed_at"]?.stringValue
        truncated = raw["truncated"]?.boolValue
        oversized = raw["oversized"]?.boolValue
        bytes = raw["bytes"]?.wireIntegerValue
        self.raw = raw
    }

    // The producer measures ensure_ascii=False JSON with default spaces. Outer ctl JSON can
    // ASCII-escape the same record to many more bytes. Measure an unescaped compact lower bound:
    // exact minimal JSON string costs, structural delimiters, and one byte per finite number.
    // This never exceeds the producer profile (including numeric spelling differences), so it
    // cannot reject valid Unicode/control-rich records. The preparse 262144-byte transport gate
    // bounds the document admitted to JSON parsing, not raw process capture or heap usage.
    // This is a conservative per-record admissibility check.
    private static func fitsSerializationLowerBound(_ raw: [String: JSONValue]) -> Bool {
        var remaining = 16384
        return consume(.object(raw), remaining: &remaining)
    }

    private static func consume(_ value: JSONValue, remaining: inout Int) -> Bool {
        switch value {
        case .string(let text): return consumeString(text, remaining: &remaining)
        case .null: remaining -= 4
        case .bool(let flag): remaining -= flag ? 4 : 5
        case .number(let number, _):
            guard number.isFinite else { return false }
            remaining -= 1
        case .array(let values):
            remaining -= 2
            for (index, value) in values.enumerated() {
                if index > 0 { remaining -= 1 }
                guard remaining >= 0, consume(value, remaining: &remaining) else { return false }
            }
        case .object(let fields):
            remaining -= 2
            for (index, pair) in fields.enumerated() {
                remaining -= index > 0 ? 2 : 1 // comma (after first field) and colon
                guard remaining >= 0, consumeString(pair.key, remaining: &remaining),
                      consume(pair.value, remaining: &remaining) else { return false }
            }
        }
        return remaining >= 0
    }

    private static func consumeString(_ text: String, remaining: inout Int) -> Bool {
        remaining -= 2
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 8, 9, 10, 12, 13, 34, 92: remaining -= 2
            case 0 ... 31: remaining -= 6
            default: remaining -= scalar.utf8.count
            }
            if remaining < 0 { return false }
        }
        return remaining >= 0
    }
}
