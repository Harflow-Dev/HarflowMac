@testable import MainWindowFeature
import SwiftUI
import Testing

@Suite struct AgentGridTests {

    private let allEnabled = [true, true, true, true]

    @Test func givenTheFirstCard_whenMovingRight_thenTheSecondCardIsNext() {
        // given / when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .right, enabled: allEnabled) == 1)
    }

    @Test func givenTheFirstRow_whenMovingDown_thenTheCardBelowIsNext() {
        // given / when / then
        #expect(AgentGrid.nextIndex(from: 1, direction: .down, enabled: allEnabled) == 3)
    }

    @Test func givenTheEdges_whenMovingOutward_thenThereIsNoNextCard() {
        // given / when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .left, enabled: allEnabled) == nil)
        #expect(AgentGrid.nextIndex(from: 0, direction: .up, enabled: allEnabled) == nil)
        #expect(AgentGrid.nextIndex(from: 3, direction: .right, enabled: allEnabled) == nil)
        #expect(AgentGrid.nextIndex(from: 3, direction: .down, enabled: allEnabled) == nil)
    }

    @Test func givenADisabledNeighbour_whenMovingHorizontally_thenItIsSkipped() {
        // given
        let enabled = [true, false, true, true]

        // when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .right, enabled: enabled) == 2)
    }

    @Test func givenADisabledCardBelow_whenMovingDown_thenNothingIsNext() {
        // given
        let enabled = [true, true, false, true]

        // when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .down, enabled: enabled) == nil)
    }
}
