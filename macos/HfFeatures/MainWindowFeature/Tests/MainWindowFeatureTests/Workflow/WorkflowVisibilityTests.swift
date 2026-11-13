import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - WorkflowVM poll gating and dedup (B1, B2)

@MainActor
@Suite struct WorkflowVisibilityTests {

    private func makeVM(visibility: FakeMonitorVisibility, scheduler: CapturingScheduler, reads: PollCounter,
                        raw: [String: JSONValue]) -> WorkflowVM {
        let useCase = MockWorkflowUseCase()
        useCase.stubBackendCatalog()
        given(useCase).activityRuntime().willReturn(QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])))
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockWorkflowRouting()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willProduce { _, _, _, _ in
            reads.increment()
            return raw
        }
        given(routing).chooseDirectory().willReturn(nil)
        given(routing).selectTask(.any).willReturn()
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                            visibility: visibility, scheduler: scheduler)
        vm.selectedRun = WorkflowRunModel(raw: raw)
        return vm
    }

    private let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "status": .string("running")]

    @Test func givenAVisibleWindow_whenAPassCompletes_thenTheNextWaitsTwoSecondsOnTheScheduler() async {
        // given
        let scheduler = CapturingScheduler()
        let reads = PollCounter()
        let vm = makeVM(visibility: FakeMonitorVisibility(), scheduler: scheduler, reads: reads, raw: raw)

        // when
        vm.didAppear()
        await waitUntil { scheduler.oneShotCount(interval: 2) == 1 }

        // then
        let firstPass = reads.value
        #expect(firstPass > 0)
        scheduler.fireOneShot(interval: 2)
        await waitUntil { reads.value > firstPass }
        #expect(reads.value > firstPass)
        vm.didDisappear()
    }

    @Test func givenAHiddenWindow_whenPolling_thenItParksAndShowingRefreshesAtOnce() async {
        // given
        let scheduler = CapturingScheduler()
        let visibility = FakeMonitorVisibility(mainWindowVisible: false)
        let reads = PollCounter()
        let vm = makeVM(visibility: visibility, scheduler: scheduler, reads: reads, raw: raw)

        // when
        vm.didAppear()
        await waitUntil { reads.value > 0 }
        await Task.yield()
        let parked = reads.value

        // then — no 2 s tick, no further read.
        #expect(scheduler.oneShotCount(interval: 2) == 0)
        #expect(reads.value == parked)

        // when
        visibility.setMainWindowVisible(true)

        // then
        await waitUntil { reads.value > parked }
        #expect(reads.value > parked)
        vm.didDisappear()
    }

    @Test func givenAnUnchangedRun_whenRefreshedAgain_thenSelectedRunIsNotReassigned() async {
        // given
        let reads = PollCounter()
        let vm = makeVM(visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler(), reads: reads, raw: raw)
        await vm.refresh()
        let changed = PollCounter()

        // when
        withObservationTracking { _ = vm.selectedRun } onChange: { changed.increment() }
        await vm.refresh()

        // then
        #expect(changed.value == 0)
    }

    @Test func givenARunningSubagentActivity_whenAnIdenticalPollArrives_thenNothingObservableChangesAndEarlierActivityIsKept() async {
        // given — an unchanged run document holding a running native subagent activation.
        let activation: [String: JSONValue] = [
            "id": .string("act1"), "node_id": .string("n1"), "role": .string("node"), "status": .string("running"),
            "execution_kind": .string("native_subagent")
        ]
        let runRaw: [String: JSONValue] = [
            "workflow_run_id": .string("run"), "status": .string("running"),
            "definition": .object(["nodes": .array([.object(["id": .string("n1"), "type": .string("agent")])])]),
            "activations": .array([.object(activation)])
        ]
        let page = WorkflowActivityPage(raw: ["workflow_run_id": .string("run"), "execution_id": .string("act1"),
                                              "events": .array([]), "has_more": .bool(true)], runID: "run", executionID: "act1")!
        let inspects = PollCounter()
        let useCase = MockWorkflowUseCase()
        useCase.stubBackendCatalog()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockWorkflowRouting()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(useCase).activityRuntime().willReturn(QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])))
        given(useCase).activity(runID: .any, executionID: .any, intent: .any, runtime: .any).willProduce { _, _, _, _ in
            inspects.increment()
            return page
        }
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn(runRaw)
        given(routing).chooseDirectory().willReturn(nil)
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                            visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.selectedRun = WorkflowRunModel(raw: runRaw)
        vm.selectedNodeID = "n1"
        await vm.sidebarTask?.value
        await waitUntil { vm.nativeActivity?.hasEarlierActivity == true && vm.nativeActivityTask == nil }
        let fetchesBefore = inspects.value
        let changed = PollCounter()
        withObservationTracking {
            _ = vm.nativeActivity
            _ = vm.initialLoadFailed
            _ = vm.selectedRun
        } onChange: { changed.increment() }

        // when
        await vm.refresh()
        await waitUntil { inspects.value > fetchesBefore && vm.nativeActivityTask == nil }

        // then — the feed was refetched (a running subagent moves without the run document
        // changing) but nothing was republished and the earlier-activity flag survived.
        #expect(inspects.value > fetchesBefore)
        #expect(changed.value == 0)
        #expect(vm.nativeActivity?.hasEarlierActivity == true)
        #expect(vm.nativeActivity?.executionID == "act1")
    }

    private struct InspectFailure: Error {}

    /// A VM holding a native-subagent activation whose `inspect` reads fail until `failures`
    /// is used up, then succeed.
    private func makeNativeVM(status: String, failures: Int, inspects: PollCounter) async throws -> WorkflowVM {
        let activation: [String: JSONValue] = [
            "id": .string("act1"), "node_id": .string("n1"), "role": .string("node"), "status": .string(status),
            "execution_kind": .string("native_subagent")
        ]
        let runRaw: [String: JSONValue] = [
            "workflow_run_id": .string("run"), "status": .string("running"),
            "definition": .object(["nodes": .array([.object(["id": .string("n1"), "type": .string("agent")])])]),
            "activations": .array([.object(activation)])
        ]
        let useCase = MockWorkflowUseCase()
        useCase.stubBackendCatalog()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockWorkflowRouting()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(useCase).activityRuntime().willReturn(QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])))
        given(useCase).activity(runID: .any, executionID: .any, intent: .any, runtime: .any).willProduce { _, _, _, _ in
            inspects.increment()
            if inspects.value <= failures { throw InspectFailure() }
            return WorkflowActivityPage(raw: ["workflow_run_id": .string("run"), "execution_id": .string("act1"),
                                              "events": .array([]), "has_more": .bool(false)], runID: "run", executionID: "act1")!
        }
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willProduce { _, options, _, _ in
            // A complete public transport snapshot supplies the attempts inventory, unlike status alone.
            guard options.contains("--snapshot") else { return runRaw }
            var full = runRaw
            var complete = activation
            complete["tasks"] = .array([])
            full["activations"] = .array([.object(complete)])
            let content = JSONValue.object(full).rendered()
            return ["monitor_snapshot": .bool(true), "workflow_run_id": .string("run"),
                    "content_sha256": .string("frozen"), "offset": .number(0),
                    "total_characters": .number(Double(content.utf8.count)), "chunk": .string(content), "next_cursor": .null]
        }
        given(routing).chooseDirectory().willReturn(nil)
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                            visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let complete = try await vm.runPolling.load(id: "run", useCase: useCase)
        vm.selectedRun = WorkflowRunModel(raw: complete)
        vm.selectedNodeID = "n1"
        return vm
    }

    @Test func givenAFailedActivityRead_whenALaterPollSucceeds_thenTheErrorClearsOnceAndIdenticalPollsStayQuiet() async throws {
        // given — the first read fails.
        let inspects = PollCounter()
        let vm = try await makeNativeVM(status: "running", failures: 1, inspects: inspects)
        await vm.sidebarTask?.value
        await waitUntil { vm.nativeActivity?.error != nil && vm.nativeActivityTask == nil }

        // when — the next (unchanged) poll succeeds.
        await vm.refresh()
        await waitUntil { vm.nativeActivity?.error == nil && vm.nativeActivityTask == nil }

        // then — cleared.
        #expect(vm.nativeActivity?.error == nil)

        // and — a further identical successful poll publishes nothing.
        let changed = PollCounter()
        let fetches = inspects.value
        withObservationTracking { _ = vm.nativeActivity } onChange: { changed.increment() }
        await vm.refresh()
        await waitUntil { inspects.value > fetches && vm.nativeActivityTask == nil }
        #expect(changed.value == 0)
    }

    @Test func givenASettledExecutionWhoseFirstReadFailed_whenPollsContinue_thenItRetriesUntilOneSucceedsThenStops() async throws {
        // given — a completed execution, first read fails.
        let inspects = PollCounter()
        let vm = try await makeNativeVM(status: "completed", failures: 1, inspects: inspects)
        await vm.sidebarTask?.value
        await waitUntil { vm.nativeActivity?.error != nil && vm.nativeActivityTask == nil }
        #expect(inspects.value == 1)

        // when — the next poll retries and succeeds.
        await vm.refresh()
        await waitUntil { inspects.value == 2 && vm.nativeActivityTask == nil && vm.nativeActivity?.loaded == true }
        #expect(vm.nativeActivity?.error == nil)

        // then — later polls make no fetches.
        await vm.refresh()
        await vm.refresh()
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(inspects.value == 2)
    }

    @Test func givenAChangedRun_whenRefreshed_thenSelectedRunIsReassigned() async {
        // given
        let useCase = MockWorkflowUseCase()
        useCase.stubBackendCatalog()
        given(useCase).activityRuntime().willReturn(QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])))
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockWorkflowRouting()
        let status = PollCounter()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willProduce { [raw] _, _, _, _ in
            status.increment()
            var next = raw
            next["status"] = .string(status.value > 1 ? "paused" : "running")
            return next
        }
        given(routing).chooseDirectory().willReturn(nil)
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                            visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await vm.refresh()
        let changed = PollCounter()
        withObservationTracking { _ = vm.selectedRun } onChange: { changed.increment() }

        // when
        await vm.refresh()

        // then
        #expect(changed.value == 1)
        #expect(vm.selectedRun?.status == "paused")
    }
}
