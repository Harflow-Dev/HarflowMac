@testable import PbUI
import Testing

// MARK: - GroupedFormTests

@Suite struct GroupedFormTests {
    @Test func givenCallerBoundsAndStep_whenFindingAdjacentValue_thenOnlyLegalChangesAreOffered() {
        // given
        let range = 1 ... 5
        // when / then
        #expect(CompactStepper.adjacentValue(3, in: range, step: 2, increment: true) == 5)
        #expect(CompactStepper.adjacentValue(3, in: range, step: 2, increment: false) == 1)
        #expect(CompactStepper.adjacentValue(5, in: range, step: 1, increment: true) == nil)
        #expect(CompactStepper.adjacentValue(1, in: range, step: 1, increment: false) == nil)
    }

    @Test func givenExtremeOrInvalidStep_whenFindingAdjacentValue_thenNoOverflowOrIllegalChangeOccurs() {
        // given
        let range = Int.min ... Int.max
        // when / then
        #expect(CompactStepper.adjacentValue(Int.max, in: range, step: 1, increment: true) == nil)
        #expect(CompactStepper.adjacentValue(Int.min, in: range, step: 1, increment: false) == nil)
        #expect(CompactStepper.adjacentValue(3, in: range, step: 0, increment: true) == nil)
    }
}
