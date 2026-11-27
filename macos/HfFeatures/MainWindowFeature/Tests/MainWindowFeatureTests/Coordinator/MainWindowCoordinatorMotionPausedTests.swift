import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - RawVisibilityFeed

/// A `MonitorVisibility` whose window-visibility publisher forwards every send, duplicates included,
/// so a test can prove the coordinator does not write an unchanged value.
private final class RawVisibilityFeed: MonitorVisibility, @unchecked Sendable {
    private let subject: CurrentValueSubject<Bool, Never>

    init(visible: Bool) { self.subject = CurrentValueSubject(visible) }

    var mainWindowVisible: Bool { subject.value }
    var menuBarPopoverOpen: Bool { false }
    func mainWindowVisiblePublisher() -> AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
    func menuBarPopoverOpenPublisher() -> AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    func waitForMainWindowVisible() async {}
    func setMainWindowVisible(_ visible: Bool) { subject.send(visible) }
    func setMenuBarPopoverOpen(_: Bool) {}
}

// MARK: - WriteCounter

private final class WriteCounter: @unchecked Sendable {
    var total = 0
}

// MARK: - MainWindowCoordinatorMotionPausedTests

@MainActor
@Suite struct MainWindowCoordinatorMotionPausedTests {
    private func makeSUT(visible: Bool) -> (sut: MainWindowCoordinator, feed: RawVisibilityFeed) {
        let feed = RawVisibilityFeed(visible: visible)
        return (MainWindowCoordinator(parent: MockCoordinator(), monitorVisibility: feed), feed)
    }

    /// Returns once every main-queue delivery queued before this call has run.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func givenVisibilityFalse_whenPublished_thenCoordinatorMotionPausedIsTrue() async {
        // given
        let (sut, feed) = makeSUT(visible: true)
        sut.subscribeToMotionVisibility()
        await drainMainQueue()
        #expect(!sut.motionPaused)

        // when
        feed.setMainWindowVisible(false)
        await drainMainQueue()

        // then
        #expect(sut.motionPaused)
    }

    @Test func givenHiddenWindow_whenVisibilityReturns_thenMotionPausedClears() async {
        // given
        let (sut, feed) = makeSUT(visible: false)
        sut.subscribeToMotionVisibility()
        await drainMainQueue()
        #expect(sut.motionPaused)

        // when
        feed.setMainWindowVisible(true)
        await drainMainQueue()

        // then
        #expect(!sut.motionPaused)
    }

    @Test func givenRepeatedEqualVisibility_whenPublished_thenMotionPausedIsNotRewritten() async {
        // given
        let (sut, feed) = makeSUT(visible: false)
        sut.subscribeToMotionVisibility()
        await drainMainQueue()
        #expect(sut.motionPaused)
        let writes = WriteCounter()
        withObservationTracking { _ = sut.motionPaused } onChange: { writes.total += 1 }

        // when
        feed.setMainWindowVisible(false)
        feed.setMainWindowVisible(false)
        await drainMainQueue()

        // then
        #expect(writes.total == 0)
        #expect(sut.motionPaused)
    }

    @Test func givenStoppedObservation_whenVisibilityChanges_thenMotionPausedIsUnchanged() async {
        // given
        let (sut, feed) = makeSUT(visible: true)
        sut.subscribeToMotionVisibility()
        await drainMainQueue()

        // when
        sut.stopShellObservation()
        feed.setMainWindowVisible(false)
        await drainMainQueue()

        // then
        #expect(!sut.motionPaused)
    }

    @Test func givenPreviewCoordinator_whenAskedForMotionPaused_thenItIsFalse() {
        // given
        let sut = MainWindowNavigationCoordinatorMock()

        // when / then
        #expect(!sut.motionPaused)
    }
}
