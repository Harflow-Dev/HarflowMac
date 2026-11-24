import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct InteractionEventNotifierTests {
    private func event(_ id: String = "question-1", state: String = "pending", kind: String = "question",
                       responder: String = "caller", at timestamp: Double = 200, task: String? = nil,
                       interaction: String? = "point-1") -> InteractionNotificationEvent {
        var raw: [String: JSONValue] = [
            "event_id": .string(id), "state": .string(state), "kind": .string(kind),
            "title": .string("Release checklist"), "answer": .string("Use staging."),
            "question": .string("Which target?"), "answered_by": .string(responder),
            "occurred_at": .number(timestamp), "workflow_run_id": .string("run12345"),
            "source_workflow_run_id": .string("run67890")
        ]
        if let task { raw["task_id"] = .string(task) }
        if let interaction { raw["interaction_id"] = .string(interaction) }
        return InteractionNotificationEvent(raw)!
    }

    private func sut(center: GatedCenter, canNotify: Bool = true, needsYou: Bool = true) -> InteractionEventNotifier {
        let settings = MockSettingsRepository()
        given(settings).notifyOnNeedsYou.willReturn(needsYou)
        given(settings).notifyOnFinish.willReturn(needsYou)
        return InteractionEventNotifier(
            tooling: NullToolEnvironmentRepository(), install: NullInstallRepository(), settings: settings,
            scheduler: NullScheduling(), center: center, canNotify: { canNotify }
        )
    }

    @Test func givenAnsweredEvent_whenDelivered_thenNothingIsPostedAndThePendingIdentifierIsRemoved() async {
        // given
        let center = GatedCenter()
        let notifier = sut(center: center)
        let identifier = "interaction:run12345|run67890||point-1"
        // when
        let handled = await notifier.deliver(event("answer-1", state: "answered"), isCurrent: { true })
        // then
        #expect(handled)
        #expect(center.delivered.isEmpty)
        #expect(center.removedDelivered == [identifier])
        #expect(center.removedPending == [identifier])
    }

    @Test func givenNotificationsOff_whenAnswered_thenRemovalStillHappens() async {
        // given
        let center = GatedCenter()
        let notifier = sut(center: center, needsYou: false)
        // when
        _ = await notifier.deliver(event("answer-1", state: "answered"), isCurrent: { true })
        // then
        #expect(center.removedDelivered == ["interaction:run12345|run67890||point-1"])
    }

    @Test func givenNoAppBundle_whenAnswered_thenTheCenterIsNeverTouched() async {
        // given
        let center = GatedCenter()
        let notifier = sut(center: center, canNotify: false)
        // when
        _ = await notifier.deliver(event("answer-1", state: "answered"), isCurrent: { true })
        let permission = await notifier.permission()
        // then
        #expect(center.removedDelivered.isEmpty)
        #expect(center.removedPending.isEmpty)
        #expect(permission == nil)
    }

    @Test func givenCannotNotify_whenPermissionRead_thenNilAndCentreUntouched() async {
        // given
        let center = GatedCenter()
        center.setStatus(.denied)
        let notifier = sut(center: center, canNotify: false)
        // when
        let permission = await notifier.permission()
        // then
        #expect(permission == nil)
        #expect(center.touchCount == 0)
    }

    @Test func givenAnApp_whenReadingPermission_thenTheCentreStatusIsReturned() async {
        // given
        let center = GatedCenter()
        center.setStatus(.denied)
        // when
        let permission = await sut(center: center).permission()
        // then
        #expect(permission == .denied)
    }

    @Test func givenPendingAndAnsweredRows_whenBuildingIdentifiers_thenTheyShareOneKeyAndTasksKeepTheirEventID() {
        // given / when / then
        #expect(InteractionEventNotifier.identifier(event("p")) == InteractionEventNotifier.identifier(event("a", state: "answered")))
        #expect(InteractionEventNotifier.identifier(event("p", task: "task1")) == "interaction:run12345|run67890|task1|point-1")
        #expect(InteractionEventNotifier.identifier(event("task:t1:completed", state: "completed", kind: "task")) == "interaction-task:t1:completed")
        #expect(InteractionEventNotifier.identifier(event("old", interaction: nil)) == "interaction-old")
    }

    @Test func givenQuestionApprovalAndRecovery_whenBuildingBanners_thenTitlesAndTypedDestinationAreRetained() {
        // given / when
        let question = InteractionEventNotifier.content(event())
        let approval = InteractionEventNotifier.content(event(kind: "approval", task: "task1"))
        // then
        #expect(question.title == "Question: Release checklist")
        #expect(question.body == "Which target?")
        #expect(question.userInfo as? [String: String] == [
            "needs_you_kind": "question", "workflow_run_id": "run12345", "interaction_id": "point-1"
        ])
        #expect(approval.title == "Approval: Release checklist")
        #expect(approval.userInfo["task_id"] as? String == "task1")
        #expect(InteractionEventNotifier.content(event(kind: "recovery")).title == "Recovery: Release checklist")
    }

    @Test func givenATaskEventWithARun_whenBuildingContent_thenTaskIDIsTheDestination() {
        // given
        let finished = event("task:t1:completed", state: "completed", kind: "task", task: "t1", interaction: "t1")
        // when
        let content = InteractionEventNotifier.content(finished)
        // then
        #expect(content.userInfo as? [String: String] == ["task_id": "t1"])
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

    private func versionInfo(capabilities: [String], root: String = NSHomeDirectory() + "/.harflow") -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1,"
            + "\"product_version\":\"0.0.1\",\"component\":\"engine\",\"state_root\":\"\(root)\","
            + "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},"
            + "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}},"
            + "\"capabilities\":[\(list)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
    }

    private func page(eventID: String, at timestamp: Double) -> String {
        let row = "{\"event_id\":\"\(eventID)\",\"state\":\"pending\",\"kind\":\"question\",\"title\":\"Release checklist\","
            + "\"question\":\"Which target?\",\"monitor_available\":true,\"occurred_at\":\(timestamp)}"
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

    // MARK: - Feed availability and answered rows

    private func answeredAndPendingRunner(_ rows: [String]) -> StubProcessRunner {
        let info = versionInfo(capabilities: baseCapabilities + ["interaction-events.v1"])
        let body = "{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"0.0.1\","
            + "\"result\":{\"events\":[\(rows.joined(separator: ","))],\"cycle_complete\":true,\"history_incomplete\":false}}"
        return StubProcessRunner { call in
            call.arguments == ["version-info", "--json"] ? .success(stdout(info)) : .success(stdout(body))
        }
    }

    private func row(_ id: String, state: String, at timestamp: Double) -> String {
        "{\"event_id\":\"\(id)\",\"state\":\"\(state)\",\"kind\":\"question\",\"title\":\"Release checklist\","
            + "\"question\":\"Which target?\",\"answer\":\"Use staging.\",\"answered_by\":\"caller\",\"monitor_available\":true,"
            + "\"workflow_run_id\":\"run1\",\"source_workflow_run_id\":\"run1\",\"interaction_id\":\"p1\",\"occurred_at\":\(timestamp)}"
    }

    @Test func givenPendingAndAnsweredInOnePage_whenProcessed_thenNothingIsPosted() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tooling = MockToolEnvironmentRepository()
        let stub = answeredAndPendingRunner([
            row("e:0:pending", state: "pending", at: 1_758_000_100), row("e:1:answered", state: "answered", at: 1_758_000_200)
        ])
        given(tooling).ctl().willReturn(.success(client(stub)))
        let scheduler = CapturingScheduler()
        let center = GatedCenter()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: center, defaults: scratch.defaults)
        // when
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // then
        #expect(center.delivered.isEmpty)
        #expect(center.removedDelivered == ["interaction:run1|run1||p1"])
    }

    @Test func givenUnsupportedCommand_whenPolled_thenFeedIsUnavailable() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client(runner(capabilities: baseCapabilities))))
        let scheduler = CapturingScheduler()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: GatedCenter(), defaults: scratch.defaults)
        #expect(sut.feedAvailability == .unknown)
        // when
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // then
        #expect(sut.feedAvailability == .unavailable)
    }

    @Test func givenASuccessfulPage_whenPolled_thenFeedIsAvailable() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client(answeredAndPendingRunner([]))))
        let scheduler = CapturingScheduler()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: GatedCenter(), defaults: scratch.defaults)
        // when
        sut.start()
        await waitUntil { sut.feedAvailability == .available }
        // then
        #expect(sut.feedAvailability == .available)
    }

    @Test func givenARuntimeSwitch_whenPolled_thenAvailabilityReturnsToUnknownBeforeTheNewAnswer() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        func switched(root: String, capabilities: [String]) -> CtlClient {
            let info = versionInfo(capabilities: capabilities, root: root)
            let body = "{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"0.0.1\","
                + "\"result\":{\"events\":[],\"cycle_complete\":true,\"history_incomplete\":false}}"
            let stub = StubProcessRunner { call in
                call.arguments == ["version-info", "--json"] ? .success(stdout(info)) : .success(stdout(body))
            }
            return CtlClient(executable: "/fake/ctl", environment: [:], runner: stub,
                             compatibilityContext: RuntimeCompatibilityContext(expectedStateRoot: root))
        }
        let first = switched(root: "/fixture/first", capabilities: baseCapabilities + ["interaction-events.v1"])
        let second = switched(root: "/fixture/second", capabilities: baseCapabilities)
        let selected = LockedBox(first)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(selected.value) }
        let scheduler = CapturingScheduler()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: GatedCenter(), defaults: scratch.defaults)
        let emissions = LockedBox<[NotificationFeedAvailability]>([])
        let cancellable = sut.feedAvailabilityPublisher().sink { value in emissions.mutate { $0.append(value) } }
        defer { cancellable.cancel() }
        sut.start()
        await waitUntil { sut.feedAvailability == .available }
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // when
        selected.mutate { $0 = second }
        scheduler.fireOneShot(interval: 3)
        // then
        await waitUntil { emissions.value.last == .unavailable }
        #expect(emissions.value == [.unknown, .available, .unknown, .unavailable])
    }

    @Test func givenAnAnsweredRowRecordedEarlier_whenItsPendingRowArrivesAlone_thenNothingIsPosted() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let pages = LockedBox<[String]>([row("e:1:answered", state: "answered", at: 1_758_000_200)])
        let info = versionInfo(capabilities: baseCapabilities + ["interaction-events.v1"])
        let stub = StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] { return .success(stdout(info)) }
            let rows = pages.value.joined(separator: ",")
            return .success(stdout("{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"0.0.1\","
                + "\"result\":{\"events\":[\(rows)],\"cycle_complete\":true,\"history_incomplete\":false}}"))
        }
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client(stub)))
        let scheduler = CapturingScheduler()
        let center = GatedCenter()
        let sut = notifier(tooling: tooling, scheduler: scheduler, center: center, defaults: scratch.defaults)
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // when
        pages.mutate { $0 = [row("e:0:pending", state: "pending", at: 1_758_000_100)] }
        scheduler.fireOneShot(interval: 3)
        await waitUntil { stub.calls.filter { $0.arguments.first == "interaction-events" }.count == 2 }
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // then
        #expect(center.delivered.isEmpty)
    }
}
