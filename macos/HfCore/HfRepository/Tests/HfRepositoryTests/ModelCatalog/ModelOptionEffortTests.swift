import Foundation
@testable import HfRepository
import Testing

struct ModelOptionEffortTests {
    private let options = [
        ModelOption(value: "a", label: "A", effortLevels: ["low"]),
        ModelOption(value: "b", label: "B", effortLevels: []),
        ModelOption(value: "c", label: "C")
    ]

    @Test func givenAnExactValue_whenLooked_thenItsLevelsAreReturnedIncludingAnEmptyList() {
        #expect(options.effortLevels(forModel: "a") == ["low"])
        #expect(options.effortLevels(forModel: "b") == [])
    }

    @Test func givenAnOptionWithoutLevels_whenLooked_thenItIsNil() {
        #expect(options.effortLevels(forModel: "c") == nil)
    }

    @Test(arguments: ["", "  ", "A", "ab", "x"])
    func givenEmptyOrNonMatchingText_whenLooked_thenItIsNil(_ text: String) {
        #expect(options.effortLevels(forModel: text) == nil)
    }

    @Test func givenSurroundingWhitespace_whenLooked_thenItStillMatches() {
        #expect(options.effortLevels(forModel: " \tb\n") == [])
    }

    @Test func givenTwoOptionsWithEqualValuesAndLabelsButDifferentLevels_whenCompared_thenTheyAreNotEqual() {
        #expect(ModelOption(value: "a", label: "A", effortLevels: nil) != ModelOption(value: "a", label: "A", effortLevels: []))
    }
}
