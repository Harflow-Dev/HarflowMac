import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
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
            scheduler: NullScheduling(), center: center,
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

    // MARK: - Polling without the interaction-events capability

    private func versionInfo(capabilities: [String]) -> String {
        let root = NSHomeDirectory() + "/.harflow"
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1,"
            + "\"product_version\":\"0.0.1\",\"component\":\"engine\",\"state_root\":\"\(root)\","
            + "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},"
            + "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}},"
            + "\"capabilities\":[\(list)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
    }

    private func page(eventID: String, at timestamp: Double) -> String {
        let row = "{\"event_id\":\"\(eventID)\",\"state\":\"answered\",\"kind\":\"question\",\"title\":\"Release checklist\","
            + "\"answer\":\"Use staging.\",\"answered_by\":\"caller\",\"occurred_at\":\(timestamp)}"
        return "{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"0.0.1\","
            + "\"result\":{\"events\":[\(row)],\"cycle_complete\":true,\"history_incomplete\":false}}"
    }

    private func runner(capabilities: [String], eventID: String = "question-1", at timestamp: Double = 1_758_000_100) -> StubProcessRunner {
        let info = versionInfo(capabilities: capabilities)
        let body = page(eventID: eventID, at: timestamp)
        return StubProcessRunner { call in
            call.arguments == ["version-info", "--json"] ? .success(stdout(info)) : .success(stdout(body))
        }
    }

    private func client(_ runner: StubProcessRunner) -> CtlClient {
        CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
    }

    private func notifier(tooling: MockToolEnvironmentRepository, scheduler: CapturingScheduler, center: GatedCenter,
                          defaults: UserDefaults) -> InteractionEventNotifier {
        let install = MockInstallRepository()
        given(install).setupState.willReturn(.ready)
        let settings = MockSettingsRepository()
        given(settings).notifyOnNeedsYou.willReturn(true)
        given(settings).notifyOnFinish.willReturn(true)
        return InteractionEventNotifier(tooling: tooling, install: install, settings: settings, scheduler: scheduler,
                                        center: center, defaults: defaults, canNotify: { true })
    }

    private let baseCapabilities = ["ctl.v1", "setup.v1", "events.v1", "messaging.v1"]

    @Test func givenEngineWithoutTheCapability_whenPolling_thenNothingIsPostedAndTheNextCallWaitsThreeSeconds() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let stub = runner(capabilities: baseCapabilities)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client(stub)))
        let scheduler = CapturingScheduler()
        let center = GatedCenter()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: center, defaults: scratch.defaults)
        // when
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // then
        let probes = stub.calls.filter { $0.arguments == ["version-info", "--json"] }.count
        #expect(probes == 1)
        #expect(!stub.calls.contains { $0.arguments.first == "interaction-events" })
        #expect(center.delivered.isEmpty)
        // and the loop only proceeds once the wait is released
        scheduler.fireOneShot(interval: 3)
        await waitUntil { stub.calls.filter { $0.arguments == ["version-info", "--json"] }.count == 2 }
        #expect(center.delivered.isEmpty)
    }

    @Test func givenCapabilityMissingThenPresent_whenPolling_thenDeliveryResumes() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let without = client(runner(capabilities: baseCapabilities))
        let with = client(runner(capabilities: baseCapabilities + ["interaction-events.v1"]))
        let upgraded = LockedBox(false)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(upgraded.value ? with : without) }
        let scheduler = CapturingScheduler()
        let center = GatedCenter()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: center, defaults: scratch.defaults)
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        #expect(center.delivered.isEmpty)
        // when
        upgraded.mutate { $0 = true }
        scheduler.fireOneShot(interval: 3)
        // then
        await waitUntil { center.delivered == ["interaction-question-1"] }
        #expect(center.delivered == ["interaction-question-1"])
    }
}
