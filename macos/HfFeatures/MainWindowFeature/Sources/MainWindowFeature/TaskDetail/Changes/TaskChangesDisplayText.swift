//
//  TaskChangesDisplayText.swift
//  MainWindowFeature
//
//  Display-safe text for stored change provenance: paths, repository names and provenance values come from a
//  repository the agent could write to, so anything that could mislead a reader or break a line is spelled out.
//

import Foundation
import MonitorCore

// MARK: - TaskChangesDisplayText

/// Escapes bytes and strings for display. The original bytes stay the only thing used to address a row.
enum TaskChangesDisplayText {

    /// Escapes `bytes`:
    /// - valid UTF-8 decodes as text;
    /// - each byte of an invalid sequence (overlong forms, surrogates, a truncated tail) renders as `\xNN`;
    /// - C0 controls and DEL render as `\xNN`, C1 controls as `\u{XXXX}`;
    /// - bidi controls (U+202A to U+202E, U+2066 to U+2069), U+2028, U+2029 and every other General_Category `Cf`
    ///   character render as `\u{XXXX}`;
    /// - a literal backslash renders as `\\`.
    static func escaped(_ bytes: Data) -> String {
        let source = Array(bytes)
        var output = ""
        var index = 0
        while index < source.count {
            if let (scalar, length) = decode(source, at: index) {
                output += render(scalar)
                index += length
            } else {
                output += hex(source[index])
                index += 1
            }
        }
        return output
    }

    /// Escapes a string through its UTF-8 bytes.
    static func escaped(_ text: String) -> String { escaped(Data(text.utf8)) }

    /// Escapes a stored path's bytes.
    static func escaped(_ path: TaskChangesPath) -> String { escaped(path.bytes) }

    // MARK: - Private

    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return "\\x" + String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0x0F)])
    }

    private static func render(_ scalar: Unicode.Scalar) -> String {
        let value = scalar.value
        if scalar == "\\" { return "\\\\" }
        if value < 0x20 || value == 0x7F { return hex(UInt8(value)) }
        if (0x80 ... 0x9F).contains(value) { return unicode(value) }
        switch scalar.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator: return unicode(value)
        default: return String(scalar)
        }
    }

    private static func unicode(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "\\u{" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "}"
    }

    /// One strictly valid UTF-8 scalar at `index`, or `nil` when the bytes there are not one.
    private static func decode(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let lead = bytes[index]
        func continuation(_ offset: Int, in range: ClosedRange<UInt8> = 0x80 ... 0xBF) -> UInt32? {
            guard index + offset < bytes.count, range.contains(bytes[index + offset]) else { return nil }
            return UInt32(bytes[index + offset] & 0x3F)
        }
        switch lead {
        case 0x00 ... 0x7F:
            return (Unicode.Scalar(lead), 1)
        case 0xC2 ... 0xDF:
            guard let second = continuation(1) else { return nil }
            return Unicode.Scalar(UInt32(lead & 0x1F) << 6 | second).map { ($0, 2) }
        case 0xE0 ... 0xEF:
            let second: ClosedRange<UInt8> = lead == 0xE0 ? 0xA0 ... 0xBF : lead == 0xED ? 0x80 ... 0x9F : 0x80 ... 0xBF
            guard let second = continuation(1, in: second), let third = continuation(2) else { return nil }
            return Unicode.Scalar(UInt32(lead & 0x0F) << 12 | second << 6 | third).map { ($0, 3) }
        case 0xF0 ... 0xF4:
            let second: ClosedRange<UInt8> = lead == 0xF0 ? 0x90 ... 0xBF : lead == 0xF4 ? 0x80 ... 0x8F : 0x80 ... 0xBF
            guard let second = continuation(1, in: second), let third = continuation(2), let fourth = continuation(3) else { return nil }
            return Unicode.Scalar(UInt32(lead & 0x07) << 18 | second << 12 | third << 6 | fourth).map { ($0, 4) }
        default:
            return nil
        }
    }
}
