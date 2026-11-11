import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

@Suite struct InteractionEventNotifierTests {
    private func event(_ id: String = "question-1", state: String = "answered", kind: String = "question",
                       responder: String = "caller", at timestamp: Double = 200) -> InteractionNotificationEvent {
        InteractionNotificationEvent([
            "event_id": .string(id), "state": .string(state), "kind": .string(kind),
            "title": .string("Release checklist"), "answer": .string("Use staging."),
            "question": .string("Which target?"), "answered_by": .string(responder),
            "occurred_at": .number(timestamp), "workflow_run_id": .string("run12345")
        ])!
    }

    @Test func givenCallerAndHarflowWinners_whenBuildingBanners_thenWinningTextAndDestinationAreRetained() {
        // given / when
        let caller = InteractionEventNotifier.content(event())
        let monitor = InteractionEventNotifier.content(event(responder: "monitor"))
        // then
        #expect(caller.title == "Answered by the caller")
        #expect(monitor.title == "Answered in Harflow")
        #expect(caller.body == "Use staging.")
        #expect(caller.userInfo["workflow_run_id"] as? String == "run12345")
    }

    @Test func givenCompletedAndFailedTasks_whenBuildingBanners_thenBothTerminalOutcomesNotify() {
        // given / when / then
        #expect(InteractionEventNotifier.content(event(state: "completed", kind: "task")).title == "Done: Release checklist")
        #expect(InteractionEventNotifier.content(event(state: "failed", kind: "task")).title == "Failed: Release checklist")
    }

    @Test func givenPersistedDelivery_whenRestarting_thenReplayIsDeduplicatedAndNewAnswerIsEligible() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let ledger = InteractionNotificationLedger(defaults: scratch.defaults, stateRoot: "/fixture/state", now: 100)
        let delivered = event()
        #expect(await !ledger.contains(delivered))
        // when
        await ledger.record(delivered)
        let restarted = InteractionNotificationLedger(defaults: scratch.reopen(), stateRoot: "/fixture/state", now: 300)
        // then
        #expect(await restarted.contains(delivered))
        #expect(await !restarted.contains(event("new-answer", at: 250)))
        #expect(await restarted.contains(event("historical", at: 50)))
    }

    @Test func givenRuntimeChangesDuringPermission_whenAuthorizationReturns_thenOldEventIsNotPosted() async {
        // given
        let center = GatedCenter()
        center.hold(.authorization)
        let current = LockedBox(true)
        let notifier = InteractionEventNotifier(
            tooling: NullToolEnvironmentRepository(), install: NullInstallRepository(), settings: NullSettingsRepository(),
            scheduler: NullScheduling(), center: center, legacy: NullNeedsYouNotifier(), mode: NotificationDeliveryMode(),
            canNotify: { true }
        )
        let shown = event()
        let operation = Task { await notifier.deliver(shown, isCurrent: { current.value }) }
        await waitUntil { center.hasReached(.authorization) }
        // when
        current.mutate { $0 = false }
        center.release(.authorization)
        let delivered = await operation.value
        // then
        #expect(!delivered)
        #expect(center.delivered.isEmpty)
    }

    @Test func givenAnotherStateRoot_whenReadingDeduplication_thenDeliveryDoesNotLeakAcrossRoots() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let first = InteractionNotificationLedger(defaults: scratch.defaults, stateRoot: "/fixture/first", now: 100)
        await first.record(event())
        // when
        let second = InteractionNotificationLedger(defaults: scratch.reopen(), stateRoot: "/fixture/second", now: 100)
        // then
        #expect(await !second.contains(event()))
    }
}
