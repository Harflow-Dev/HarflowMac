import AppKit
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

/// Which feed rows fade in on arrival, decided from the coordinator's own state: `notePendingArrivals`
/// keeps the set of rows added while following, and `arrivalFades` reads it with the mounted set and
/// the cell's hosting state. No window is needed: the coordinator and a cell are driven directly.
@MainActor @Suite(.serialized) struct ActivityFeedArrivalDecisionTests {
    private func rowEntry(_ seq: Int) -> ActivityFeedNativeEntry {
        .row(ActivityFeedNativeEntry.Row(row: .single(ActivityFixture.text(seq), markdown: nil), isExpanded: false, topSpacing: 20))
    }

    private func rows(_ range: ClosedRange<Int>) -> [ActivityFeedNativeEntry] { range.map(rowEntry) }

    private func ids(_ range: ClosedRange<Int>) -> Set<String> { Set(rows(range).map(\.id)) }

    private func hostedCell(_ entry: ActivityFeedNativeEntry) -> ActivityFeedNativeCell {
        let cell = ActivityFeedNativeCell(frame: CGRect(x: 0, y: 0, width: 403, height: 100))
        cell.configure(root: root(entry), id: entry.id)
        return cell
    }

    private func root(_ entry: ActivityFeedNativeEntry) -> ActivityFeedNativeRowRoot {
        ActivityFeedNativeRowRoot(entry: entry, start: nil, horizontalPadding: 12, showsPromptBubble: true, style: .standard,
                                  environment: ActivityFeedNativeEnvironment(EnvironmentValues()), actions: ActivityFeedNativeActions(),
                                  availableWidth: 403)
    }

    // MARK: Pending arrivals

    @Test func givenInitialLoadWhileFollowing_whenNoted_thenEveryRowIsPendingAndNothingElse() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let next = rows(1 ... 4) + [.bottom(topSpacing: 0)]
        // when
        coordinator.notePendingArrivals(next: next, following: true)
        // then
        #expect(coordinator.pendingArrivals == ids(1 ... 4), "only .row entries fade, never the bottom sentinel")
    }

    @Test func givenFollowingFeed_whenRowAppended_thenOnlyTheNewRowJoins() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        coordinator.entries = rows(1 ... 3) + [.bottom(topSpacing: 0)]
        // when
        coordinator.notePendingArrivals(next: rows(1 ... 4) + [.bottom(topSpacing: 0)], following: true)
        // then
        #expect(coordinator.pendingArrivals == ids(4 ... 4))
    }

    @Test func givenTailAndHeaderEntries_whenNotedWhileFollowing_thenTheyAreNotPending() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let tail = ActivityFeedNativeEntry.tail(.plainText("Working"), topSpacing: 12)
        // when
        coordinator.notePendingArrivals(next: [.header(.loading), rowEntry(1), tail, .bottom(topSpacing: 0)], following: true)
        // then
        #expect(coordinator.pendingArrivals == ids(1 ... 1))
    }

    @Test func givenNotFollowing_whenRowsAppended_thenNothingIsPending() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        coordinator.entries = rows(1 ... 3)
        // when
        coordinator.notePendingArrivals(next: rows(1 ... 5), following: false)
        // then
        #expect(coordinator.pendingArrivals.isEmpty)
    }

    @Test func givenPendingRows_whenABuildHappensWhileNotFollowing_thenThePendingSetIsCleared() throws {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        coordinator.notePendingArrivals(next: rows(1 ... 3), following: true)
        coordinator.entries = rows(1 ... 3)
        try #require(coordinator.pendingArrivals == ids(1 ... 3))
        // when
        coordinator.notePendingArrivals(next: rows(1 ... 3), following: false)
        // then
        #expect(coordinator.pendingArrivals.isEmpty)
    }

    @Test func givenRowsAddedWhileNotFollowing_whenFollowingResumes_thenTheyNeverJoin() {
        // given: rows 4 and 5 were built while the reader was above the tail
        let coordinator = ActivityFeedNativeList.Coordinator()
        coordinator.entries = rows(1 ... 3)
        coordinator.notePendingArrivals(next: rows(1 ... 5), following: false)
        coordinator.entries = rows(1 ... 5)
        // when: the next build follows again and adds one row
        coordinator.notePendingArrivals(next: rows(1 ... 6), following: true)
        // then
        #expect(coordinator.pendingArrivals == ids(6 ... 6))
    }

    @Test func givenPendingRows_whenEntriesAreRemoved_thenThePendingSetIsPruned() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        coordinator.notePendingArrivals(next: rows(1 ... 4), following: true)
        coordinator.entries = rows(1 ... 4)
        // when: the window slides past rows 1 and 2
        coordinator.notePendingArrivals(next: rows(3 ... 4), following: true)
        // then
        #expect(coordinator.pendingArrivals == ids(3 ... 4))
    }

    @Test func givenRepeatedBuildOfTheSameEntries_whenFollowing_thenPendingIsStable() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        coordinator.notePendingArrivals(next: rows(1 ... 2), following: true)
        coordinator.entries = rows(1 ... 2)
        coordinator.pendingArrivals.remove(rows(1 ... 1)[0].id)
        // when
        coordinator.notePendingArrivals(next: rows(1 ... 2), following: true)
        // then: a mounted row is not re-added by a build that only refreshes it
        #expect(coordinator.pendingArrivals == ids(2 ... 2))
    }

    // MARK: Arrival decision

    @Test func givenPendingUnmountedRowAndFreshCell_whenDecided_thenItFades() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let entry = rowEntry(1)
        coordinator.pendingArrivals = [entry.id]
        // when / then
        #expect(coordinator.arrivalFades(entry: entry, in: ActivityFeedNativeCell()))
    }

    @Test func givenPendingRowThatAlreadyMounted_whenDecided_thenItDoesNotFade() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let entry = rowEntry(1)
        coordinator.pendingArrivals = [entry.id]
        coordinator.mountedIDs = [entry.id]
        // when / then
        #expect(!coordinator.arrivalFades(entry: entry, in: ActivityFeedNativeCell()))
    }

    @Test func givenRowThatIsNotPending_whenDecided_thenItDoesNotFade() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        // when / then
        #expect(!coordinator.arrivalFades(entry: rowEntry(1), in: ActivityFeedNativeCell()))
    }

    @Test func givenNonRowEntriesInThePendingSet_whenDecided_thenNoneFades() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let entries: [ActivityFeedNativeEntry] = [
            .bottom(topSpacing: 0), .header(.loading), .tail(.plainText("Working"), topSpacing: 12)
        ]
        coordinator.pendingArrivals = Set(entries.map(\.id))
        // when / then
        for entry in entries {
            #expect(!coordinator.arrivalFades(entry: entry, in: ActivityFeedNativeCell()), "\(entry.id)")
        }
    }

    @Test func givenCellAlreadyHostingTheEntry_whenDecided_thenAStreamingRefreshDoesNotFade() {
        // given: pending, not yet mounted, but the cell already hosts this very entry
        let coordinator = ActivityFeedNativeList.Coordinator()
        let entry = rowEntry(1)
        coordinator.pendingArrivals = [entry.id]
        let cell = hostedCell(entry)
        // when / then
        #expect(!coordinator.arrivalFades(entry: entry, in: cell))
    }

    @Test func givenRecycledCellHostingAnotherEntry_whenGivenAPendingEntry_thenItFades() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let cell = hostedCell(rowEntry(1))
        let incoming = rowEntry(2)
        coordinator.pendingArrivals = [incoming.id]
        // when / then
        #expect(coordinator.arrivalFades(entry: incoming, in: cell))
    }

    @Test func givenRecycledCellGivenAnAlreadyMountedEntry_whenDecided_thenItDoesNotFade() {
        // given
        let coordinator = ActivityFeedNativeList.Coordinator()
        let cell = hostedCell(rowEntry(1))
        let incoming = rowEntry(2)
        coordinator.pendingArrivals = [incoming.id]
        coordinator.mountedIDs = [incoming.id]
        // when / then
        #expect(!coordinator.arrivalFades(entry: incoming, in: cell))
    }

    @Test func givenCellWithEntryIDButNoHost_whenDecidedForThatEntry_thenItFades() throws {
        // given: a released cell that kept nothing, then reassigned the same id
        let coordinator = ActivityFeedNativeList.Coordinator()
        let entry = rowEntry(1)
        coordinator.pendingArrivals = [entry.id]
        let cell = hostedCell(entry)
        cell.releaseHostedContent()
        cell.entryID = entry.id
        try #require(cell.host == nil)
        // when / then
        #expect(coordinator.arrivalFades(entry: entry, in: cell))
    }

    // MARK: Animation definition

    @Test func givenLayer_whenArrivalFadeAdded_thenItIsAnEaseOutOpacityFadeFromZeroToOne() throws {
        // given
        let layer = CALayer()
        // when
        ActivityFeedNativeCell.addArrivalFade(to: layer)
        // then
        let animation = try #require(layer.animation(forKey: "activityArrival") as? CABasicAnimation)
        #expect(ActivityFeedNativeCell.arrivalFadeKey == "activityArrival")
        #expect(animation.keyPath == "opacity")
        #expect((animation.fromValue as? NSNumber)?.doubleValue == 0)
        #expect((animation.toValue as? NSNumber)?.doubleValue == 1)
        #expect(animation.duration == HfMotion.arrivalDuration)
        #expect(animation.isRemovedOnCompletion)
        #expect(layer.opacity == 1, "the model opacity stays 1")
        let expected = CAMediaTimingFunction(name: .easeOut)
        let actual = try #require(animation.timingFunction)
        for index in 0 ..< 4 {
            var want: [Float] = [0, 0], got: [Float] = [0, 0]
            expected.getControlPoint(at: index, values: &want)
            actual.getControlPoint(at: index, values: &got)
            #expect(want == got, "control point \(index)")
        }
    }

    @Test func givenArrivalFadeAlreadyPlaying_whenAddedAgain_thenItReplacesRatherThanStacks() {
        // given
        let layer = CALayer()
        ActivityFeedNativeCell.addArrivalFade(to: layer)
        // when
        ActivityFeedNativeCell.addArrivalFade(to: layer)
        // then
        #expect(layer.animationKeys() == ["activityArrival"])
    }

    @Test func givenCellWithoutHost_whenArrivalFadePlayed_thenNothingHappens() {
        // given
        let cell = ActivityFeedNativeCell()
        // when / then: no host, no layer, no crash
        cell.playArrivalFade()
        #expect(cell.host == nil)
        #expect(cell.layer?.animationKeys() ?? [] == [])
    }

    @Test func givenHostedCell_whenArrivalFadePlayed_thenTheAnimationIsOnTheHostLayerNotTheCellLayer() throws {
        // given
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 200))
        window.contentView = container
        defer { window.contentView = nil; window.close() }
        let cell = ActivityFeedNativeCell(frame: CGRect(x: 0, y: 0, width: 403, height: 100))
        container.addSubview(cell)
        cell.configure(root: root(rowEntry(1)), id: rowEntry(1).id)
        let hostLayer = try #require(cell.host?.layer, "the hosting view must be layer-backed")
        // when
        cell.playArrivalFade()
        // then
        #expect(hostLayer.animationKeys() == ["activityArrival"])
        #expect(cell.layer?.animationKeys()?.contains("activityArrival") != true)
    }
}
