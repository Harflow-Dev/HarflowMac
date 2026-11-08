import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesDisplayTextTests

/// The escaping matrix for paths, repository names and provenance values.
struct TaskChangesDisplayTextTests {

    private func escaped(_ bytes: [UInt8]) -> String { TaskChangesDisplayText.escaped(Data(bytes)) }

    // MARK: Valid text

    @Test(arguments: ["README.md", "src/app.py", "caf\u{E9}.txt", "\u{65E5}\u{672C}\u{8A9E}.md", "emoji-\u{1F600}.txt", "a b.txt", ""])
    func givenValidPrintableUTF8_whenEscaped_thenItIsUnchanged(text: String) {
        // given / when
        let result = TaskChangesDisplayText.escaped(Data(text.utf8))
        // then
        #expect(result == text)
    }

    @Test func givenABackslash_whenEscaped_thenItIsDoubled() {
        // given / when
        let result = TaskChangesDisplayText.escaped("a\\b\\\\c")
        // then
        #expect(result == "a\\\\b\\\\\\\\c")
    }

    // MARK: Invalid sequences

    @Test(arguments: [
        ([0x80], "\\x80"),
        ([0xFF], "\\xff"),
        ([0xC0, 0x80], "\\xc0\\x80"),
        ([0xC1, 0xBF], "\\xc1\\xbf"),
        ([0xE0, 0x80, 0x80], "\\xe0\\x80\\x80"),
        ([0xF0, 0x80, 0x80, 0x80], "\\xf0\\x80\\x80\\x80"),
        ([0xED, 0xA0, 0x80], "\\xed\\xa0\\x80"),
        ([0xED, 0xBF, 0xBF], "\\xed\\xbf\\xbf"),
        ([0xF4, 0x90, 0x80, 0x80], "\\xf4\\x90\\x80\\x80"),
        ([0xF5, 0x80, 0x80, 0x80], "\\xf5\\x80\\x80\\x80"),
        ([0xE2, 0x82], "\\xe2\\x82"),
        ([0xF0, 0x9F, 0x98], "\\xf0\\x9f\\x98"),
        ([0xC3], "\\xc3")
    ] as [([UInt8], String)])
    func givenAnInvalidSequence_whenEscaped_thenEachByteIsSpelledAsHex(bytes: [UInt8], expected: String) {
        // given / when
        let result = escaped(bytes)
        // then
        #expect(result == expected)
    }

    @Test func givenInvalidBytesBetweenValidText_whenEscaped_thenTheTextAroundThemSurvives() {
        // given
        let bytes: [UInt8] = Array("a".utf8) + [0xFF] + Array("b".utf8) + [0xE2, 0x82] + Array("\u{E9}".utf8)
        // when
        let result = escaped(bytes)
        // then
        #expect(result == "a\\xffb\\xe2\\x82\u{E9}")
    }

    @Test func givenATruncatedSequenceFollowedByAnASCIIByte_whenEscaped_thenTheASCIIByteIsNotConsumed() {
        // given / when
        let result = escaped([0xE2, 0x82, 0x41])
        // then
        #expect(result == "\\xe2\\x82A")
    }

    // MARK: Controls

    @Test(arguments: [
        (UInt8(0x00), "\\x00"), (0x09, "\\x09"), (0x0A, "\\x0a"), (0x0D, "\\x0d"), (0x1B, "\\x1b"), (0x1F, "\\x1f"), (0x7F, "\\x7f")
    ] as [(UInt8, String)])
    func givenAC0OrDELControl_whenEscaped_thenItIsHexEscaped(byte: UInt8, expected: String) {
        // given / when
        let result = escaped([byte])
        // then
        #expect(result == expected)
    }

    // Scalars are passed by value: raw separators and controls in an argument description would split the runner's event stream.
    @Test(arguments: [0x80, 0x85, 0x9F] as [UInt32])
    func givenAC1Control_whenEscaped_thenItIsUnicodeEscaped(value: UInt32) throws {
        // given
        let text = String(try #require(Unicode.Scalar(value)))
        // when
        let result = TaskChangesDisplayText.escaped(text)
        // then
        #expect(result == String(format: "\\u{%04X}", value))
    }

    // MARK: Format characters

    @Test(arguments: [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] as [UInt32])
    func givenABidiControl_whenEscaped_thenItIsUnicodeEscaped(value: UInt32) throws {
        // given
        let scalar = String(try #require(Unicode.Scalar(value)))
        // when
        let result = TaskChangesDisplayText.escaped("a" + scalar + "b")
        // then
        #expect(result == "a" + String(format: "\\u{%04X}", value) + "b")
    }

    @Test(arguments: [0x2028, 0x2029] as [UInt32])
    func givenALineOrParagraphSeparator_whenEscaped_thenItIsUnicodeEscaped(value: UInt32) throws {
        // given
        let text = String(try #require(Unicode.Scalar(value)))
        // when
        let result = TaskChangesDisplayText.escaped(text)
        // then
        #expect(result == String(format: "\\u{%04X}", value))
    }

    @Test(arguments: [0x200B, 0x200E, 0xFEFF, 0xAD, 0xE0001] as [UInt32])
    func givenAnotherFormatCharacter_whenEscaped_thenItIsUnicodeEscaped(value: UInt32) throws {
        // given
        let text = String(try #require(Unicode.Scalar(value)))
        // when
        let result = TaskChangesDisplayText.escaped(text)
        // then
        let expected = value > 0xFFFF ? "\\u{\(String(value, radix: 16, uppercase: true))}" : String(format: "\\u{%04X}", value)
        #expect(result == expected)
    }

    // MARK: Overloads

    @Test func givenAStoredPath_whenEscaped_thenItUsesItsBytes() throws {
        // given
        let path = try #require(TaskChangesPath(bytes: Data([0x61, 0xFF, 0x2F])))
        // when
        let result = TaskChangesDisplayText.escaped(path)
        // then
        #expect(result == "a\\xff/")
    }

    @Test func givenAPathWithATrailingSlash_whenEscaped_thenTheSlashIsKept() throws {
        // given
        let path = try #require(TaskChangesPath(bytes: Data("build/".utf8)))
        // when / then
        #expect(TaskChangesDisplayText.escaped(path) == "build/")
    }
}
