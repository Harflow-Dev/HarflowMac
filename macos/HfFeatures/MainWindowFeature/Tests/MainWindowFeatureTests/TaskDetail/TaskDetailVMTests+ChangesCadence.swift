import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - Cadence

@MainActor
extension TaskDetailVMTests {

    @Test func givenASettlingResult_whenItApplies_thenTheNextReadIsFiveSecondsThenFifteenEach() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }
        #expect(rig.sut.changesCaptureSettling)
        #expect(rig.sut.changesTabCount == nil)

        // when: the first wait elapses
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.script.count == 2 && rig.scheduler.oneShotIntervals == [15] }
        rig.scheduler.fireOneShot(interval: 15)
        await waitUntil { rig.script.count == 3 && rig.scheduler.oneShotIntervals == [15] }

        // then
        #expect(rig.script.calls.map(\.key.generation) == rig.script.calls.map(\.key.generation).sorted())
        #expect(TaskChangesLifecycle.firstSettlingDelay == 5 && TaskChangesLifecycle.settlingDelay == 15 && TaskChangesLifecycle.settlingCap == 300)
    }

    @Test func givenSettlingEndsOnARead_whenItApplies_thenTheCadenceStopsAndTheSettlingFlagClears() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }
        rig.script.answerFromNowOn(.snapshot(try ChangesJSON.availableListing()))

        // when
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(!rig.sut.changesCaptureSettling)
        #expect(rig.scheduler.oneShotIntervals.isEmpty)
        #expect(await quietCallCount(rig) == 2)
    }

    @Test func givenTheLastResultIsSettlingWithTheLogFinal_whenThePaneCloses_thenTheCadenceContinues() async throws {
        // given
        let rig = try await openChangesRig(logState: .final, reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }

        // when
        rig.sut.setChangesPaneOpen(false)
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.script.count == 2 && rig.scheduler.oneShotIntervals == [15] }

        // then
        #expect(rig.sut.changesCaptureSettling)
    }

    @Test func givenAScheduledCadence_whenTheViewDisappears_thenTheWaitCancelsAndNoReadFollows() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }

        // when
        rig.sut.didDisappear()
        rig.scheduler.fireOneShot(interval: 5)

        // then
        #expect(await quietCallCount(rig) == 1)
        #expect(rig.sut.changesPresentation == .loading)
        #expect(!rig.sut.changesCaptureSettling)
    }

    @Test func givenFiveMinutesOfSettling_whenTheNextSettlingResultApplies_thenItStopsAndOffersCheckAgain() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }

        // when: the clock passes the cap before the next result lands
        rig.scheduler.advance(to: rig.scheduler.now().addingTimeInterval(TaskChangesLifecycle.settlingCap))
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.sut.changesPresentation == .settlingCapped }

        // then
        #expect(rig.scheduler.oneShotIntervals.isEmpty)
        #expect(await quietCallCount(rig) == 1, "the deadline publishes the cap without reading")
    }

    @Test func givenTheCap_whenNothingTriggersARead_thenNoReadHappensAndCheckAgainReadsFromScratch() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }
        rig.scheduler.advance(to: rig.scheduler.now().addingTimeInterval(TaskChangesLifecycle.settlingCap))
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.sut.changesPresentation == .settlingCapped }

        // when: the pane toggles and the same status is published again
        rig.sut.setChangesPaneOpen(false)
        rig.sut.setChangesPaneOpen(true)
        publishChanges(rig.scenario, to: rig)

        // then
        #expect(await quietCallCount(rig) == 1)
        #expect(rig.sut.changesPresentation == .settlingCapped)

        // when: Check again
        rig.script.answerFromNowOn(.snapshot(try ChangesJSON.availableListing()))
        rig.sut.didTapRetryChanges()
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(rig.script.count == 2)
    }

    @Test func givenTheCap_whenTheStatusTransitions_thenAFreshCapStartsAndTheCadenceRuns() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }
        rig.scheduler.advance(to: rig.scheduler.now().addingTimeInterval(TaskChangesLifecycle.settlingCap))
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.sut.changesPresentation == .settlingCapped }

        // when
        var failed = rig.scenario
        failed.taskStatus = "failed"
        failed.snapshotStatus = "failed"
        publishChanges(failed, to: rig)
        await waitUntil { rig.script.count == 2 && rig.scheduler.oneShotIntervals == [5] }

        // then: settling again, not capped, on the first-delay schedule
        #expect(rig.sut.changesPresentation != .settlingCapped)
        #expect(rig.sut.changesCaptureSettling)
    }

    @Test func givenTheCap_whenTheMemberChanges_thenAFreshCapStartsForTheNewMember() async throws {
        // given
        let scheduler = CapturingScheduler()
        let first = conversationTask("a", status: "completed", minute: 0)
        let second = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [first], stubbedMembers: [first, second], chrome: .standalone,
                                          scheduler: scheduler)
        let script = ChangesReadScript(.snapshot(try ChangesJSON.pendingSettling()))
        given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
        harness.sut.didAppear()
        harness.tasksSubject.send([first])
        await waitUntil { harness.sut.task != nil }
        harness.sut.setChangesPaneOpen(true)
        await waitUntil { scheduler.oneShotIntervals == [5] }
        scheduler.advance(to: scheduler.now().addingTimeInterval(TaskChangesLifecycle.settlingCap))
        scheduler.fireOneShot(interval: 5)
        await waitUntil { harness.sut.changesPresentation == .settlingCapped }

        // when: a follow-up turn joins the conversation
        harness.membersBox.value = [first, second]
        harness.tasksSubject.send([first, second])
        await waitUntil { script.count == 2 && script.calls.last?.key.taskID == "b" }

        // then
        #expect(harness.sut.changesPresentation != .settlingCapped)
        await waitUntil { scheduler.oneShotIntervals.last == 5 }
        harness.sut.didDisappear()
    }

    @Test func givenNoChangeInWhatIsPublished_whenAnIdenticalSettlingResultRepeats_thenNothingObservedIsWritten() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }
        let flag = ChangesObservationFlag()
        let sut = rig.sut
        withObservationTracking {
            _ = sut.changesPresentation
            _ = sut.changesCaptureSettling
        } onChange: {
            flag.set()
        }

        // when
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.script.count == 2 && rig.scheduler.oneShotIntervals == [15] }

        // then
        #expect(!flag.isSet)
    }

    @Test func givenADifferentResult_whenItApplies_thenTheObservedPresentationChanges() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }
        let flag = ChangesObservationFlag()
        let sut = rig.sut
        withObservationTracking { _ = sut.changesPresentation } onChange: { flag.set() }
        rig.script.answerFromNowOn(.snapshot(try ChangesJSON.zeroRows()))

        // when
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { flag.isSet }

        // then
        #expect(flag.isSet)
    }
}
