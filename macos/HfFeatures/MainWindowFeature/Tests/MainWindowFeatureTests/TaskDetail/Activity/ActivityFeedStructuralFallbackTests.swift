import Foundation
@testable import MainWindowFeature
import Testing

/// Pure coverage of the structural reload's removed-anchor fallback order.
struct ActivityFeedStructuralFallbackTests {

    // MARK: Fixtures

    private typealias Entry = ActivityFeedNativeReading.FallbackEntry

    private func row(_ id: String, _ minY: CGFloat, _ height: CGFloat = 100) -> Entry {
        Entry(id: id, anchorID: id, isRow: true, rect: CGRect(x: 0, y: minY, width: 400, height: height))
    }

    private func anchor(_ id: String, _ minY: CGFloat, _ height: CGFloat = 40) -> Entry {
        Entry(id: id, anchorID: id, isRow: false, rect: CGRect(x: 0, y: minY, width: 400, height: height))
    }

    private let visible = CGRect(x: 0, y: 220, width: 400, height: 300)

    private func fallback(_ entries: [Entry], surviving: Set<String>, captured: String)
        -> (id: String, relativeOffset: CGFloat)? {
        ActivityFeedNativeReading.structuralFallback(entries: entries, visible: visible, surviving: surviving,
                                                     captured: captured)
    }

    // MARK: Order

    @Test func givenAVisibleSurvivingRow_whenTheAnchorIsRemoved_thenItWinsOverThePrecedingNeighbour() {
        // given
        let entries = [row("r4", 100), row("r5", 200), row("r6", 300)]
        // when
        let result = fallback(entries, surviving: ["r4", "r6"], captured: "r5")
        // then
        #expect(result?.id == "r6")
        #expect(result?.relativeOffset == 80)
    }

    @Test func givenAVisibleTailAboveAVisibleRow_whenTheAnchorIsRemoved_thenTheRowWins() {
        // given — the tail comes first in visible order, so only the pass order picks the row.
        let entries = [row("r5", 100, 140), anchor("approval", 240, 40), row("r6", 280)]
        // when
        let result = fallback(entries, surviving: ["approval", "r6"], captured: "r5")
        // then
        #expect(result?.id == "r6")
        #expect(result?.relativeOffset == 60)
    }

    @Test func givenNoVisibleRow_whenAVisibleTailSurvives_thenTheTailWins() {
        // given
        let entries = [row("r1", 0, 100), row("r2", 100, 100), anchor("tail", 300)]
        let tallVisible = CGRect(x: 0, y: 290, width: 400, height: 100)
        // when
        let result = ActivityFeedNativeReading.structuralFallback(entries: entries, visible: tallVisible,
                                                                  surviving: ["r1", "tail"], captured: "r2")
        // then
        #expect(result?.id == "tail")
        #expect(result?.relativeOffset == 10)
    }

    @Test func givenNothingVisibleSurvives_whenTheAnchorIsRemoved_thenThePrecedingRowIsUsed() {
        // given
        let entries = [row("r1", 0), row("r2", 100), row("tall", 200, 600), row("r4", 800)]
        // when
        let result = fallback(entries, surviving: ["r1", "r2", "r4"], captured: "tall")
        // then
        #expect(result?.id == "r2")
        #expect(result?.relativeOffset == -120)
    }

    @Test func givenSurvivingRowsOnlyAboveTheViewport_whenTheAnchorIsRemoved_thenTheNeighbourNotTheEarliestRowIsUsed() {
        // given
        let entries = [row("r1", 0), row("r2", 100), row("r3", 200, 40), row("tall", 240, 600)]
        let viewport = CGRect(x: 0, y: 300, width: 400, height: 200)
        // when
        let result = ActivityFeedNativeReading.structuralFallback(entries: entries, visible: viewport,
                                                                  surviving: ["r1", "r2", "r3"], captured: "tall")
        // then
        #expect(result?.id == "r3")
        #expect(result?.relativeOffset == -100)
    }

    @Test func givenNothingVisibleSurvivesAndNoRowPrecedes_whenTheAnchorIsRemoved_thenTheFollowingRowIsUsed() {
        // given
        let entries = [row("tall", 0, 600), row("r2", 800), row("r3", 900)]
        // when
        let result = fallback(entries, surviving: ["r2", "r3"], captured: "tall")
        // then
        #expect(result?.id == "r2")
        #expect(result?.relativeOffset == 580)
    }

    @Test func givenNothingSurvives_whenTheAnchorIsRemoved_thenThereIsNoFallback() {
        // given
        let entries = [row("r1", 0), row("r2", 100)]
        // when / then
        #expect(fallback(entries, surviving: [], captured: "r2") == nil)
    }

    // MARK: Shared scan

    @Test func givenAVisibleRowAndAnEarlierOffscreenOne_whenScanned_thenTheVisibleOneIsReportedAndTheFirstKept() {
        // given
        let entries = [row("r1", 0), row("r2", 250)]
        // when
        let result = ActivityFeedNativeReading.visibleSurviving(entries: entries, visible: visible,
                                                                surviving: ["r1", "r2"], rowsOnly: true)
        // then
        #expect(result.visible?.id == "r2")
        #expect(result.first?.id == "r1")
    }

    @Test func givenNoVisibleSurvivor_whenScanned_thenOnlyTheFirstSurvivorIsReported() {
        // given
        let entries = [row("r1", 0), row("r2", 100)]
        // when
        let result = ActivityFeedNativeReading.visibleSurviving(entries: entries, visible: visible,
                                                                surviving: ["r2"], rowsOnly: true)
        // then
        #expect(result.visible == nil)
        #expect(result.first?.id == "r2")
    }
}
