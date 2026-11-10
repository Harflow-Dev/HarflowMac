import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStateTreatmentHostedTests + Mounts

extension TaskStateTreatmentHostedTests {
    func mock(status: String = "running", snapshotStatus: String? = "running", owner: String = "dead", takenOver: Bool = false) -> TaskDetailViewModelMock {
        let mock = PaneMocks.running()
        var raw = mock.task!.raw
        raw["status"] = .string(status)
        raw["taken_over"] = .bool(takenOver)
        raw["exit_code"] = nil
        mock.task = TaskInfo(.object(raw))!
        var snapshot = raw
        snapshot["status"] = .string(snapshotStatus ?? status)
        snapshot["supervision"] = .object(["owner_state": .string(owner)])
        mock.inspectorModel = InspectorModel(
            task: mock.task!, current: nil, stepCount: 3, activity: ActivityCounts(), subtaskCount: 0, ancestors: [], siblings: [],
            detail: TaskInfo(.object(snapshot))!, hasSnapshot: snapshotStatus != nil, notices: [], startedBy: "Top-level task",
            resumeCommand: mock.resumeCommand, onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in })
        mock.observationFrames = [PaneMocks.taskID: EventObservationFrame(taskID: PaneMocks.taskID,
            scope: FeatureObservationFixture.scope, logState: .incomplete)]
        return mock
    }

    @Test func givenStandaloneEvidenceChanges_whenRemountedWithLatestSnapshots_thenUnsupportedWarningsDisappear() async throws {
        // given — every row has captured activity; this exercises the mount's projection rather than a direct model.
        let inputs: [(TaskDetailViewModelMock, TaskStateTreatment.Kind?)] = [
            (mock(), .ownerLost), (mock(owner: "undecidable"), .unverified),
            (mock(status: "completed", snapshotStatus: "completed"), .reconstructed),
            (mock(status: "failed", snapshotStatus: "failed"), .unknownFailed),
            (mock(snapshotStatus: nil), nil), (mock(snapshotStatus: "completed"), nil),
            (mock(owner: "alive"), nil), (mock(takenOver: true), nil),
            (mock(status: "completed", snapshotStatus: "completed", takenOver: true), nil),
            (mock(status: "failed", snapshotStatus: "failed", takenOver: true), nil)
        ]
        let store = TaskPaneStateStore()
        store.setOpenChoice(.closed, for: "conv")
        let host = PaneHost(PaneMocks.standalone(inputs[0].0, store: store), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.pump()
        // when
        for (index, input) in inputs.enumerated() {
            host.page.host.rootView = AnyView(PaneMocks.standalone(input.0, store: store).id(index))
            await host.pump()
            let table = try table(host)
            let actual = table.owner?.entries.compactMap { entry -> TaskStateTreatment.Kind? in
                if case .taskState(let model, _) = entry { return model.kind }; return nil
            }
            // then
            #expect(actual == (input.1.map { [$0] } ?? []), "snapshot transition \(index)")
        }
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenMatchingDeadOwnerSnapshot_whenLegacyTaskMounted_thenTreatmentNeverEntersNativeFeed(chrome: TaskDetailChrome) async throws {
        // given / when
        let host = PaneHost(TaskDetailView(mock(), chrome: chrome, transcriptStyle: .standard)
            .environment(\.hfReduceMotionOverride, true), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.pump()
        // then
        #expect(treatmentIndex(try table(host)) == nil)
        #expect(Self.titles.allSatisfy { host.page.element($0) == nil })
    }

    @Test func givenInferredFailureInStandaloneTask_whenOpenEventsPressed_thenNormalPaneOpensAndSelectsEvents() async throws {
        // given
        let mock = mock(status: "failed", snapshotStatus: "failed")
        let store = TaskPaneStateStore()
        store.setOpenChoice(.closed, for: "conv")
        store.setSelectedTab(.changes, for: "conv")
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.pump()
        let table = try table(host)
        await reveal(try #require(treatmentIndex(table)), table: table, host: host)
        #expect(!host.hasPane)
        // when
        #expect(host.page.press(try #require(host.page.element("Open Events"))))
        await host.page.settle { host.hasPane }
        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: "conv") == .open)
        #expect(store.selectedTab(for: "conv") == .events)
    }

    @Test func givenDeadOwnerWarningOnRealVM_whenStopPressedThenDismissed_thenExistingSheetDoesNotCancel() async throws {
        // given
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone)
        let holder = StateStopHolder()
        given(fixture.routing).presentStopConfirmation(.any).willProduce { holder.request = $0 }
        given(fixture.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .failed(.notFound(tool: "fixture changes", searched: []))))
        }
        var raw = TaskDetailVMTests().task(liveInput: true).raw
        raw["supervision"] = .object(["owner_state": .string("dead")])
        let task = try #require(TaskInfo(.object(raw)))
        fixture.detailBox.value = task
        fixture.snapshotBox.value = task
        let host = PaneHost(StateStopMount(sut: fixture.sut, holder: holder), size: CGSize(width: 1000, height: 620))
        defer { host.close(); fixture.sut.didDisappear() }
        await host.page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([task])
        await host.page.settle { fixture.sut.stateTreatment?.kind == .ownerLost }
        let table = try table(host)
        await reveal(try #require(treatmentIndex(table)), table: table, host: host)
        // when
        #expect(host.page.press(try #require(host.page.element("Stop task"))))
        await host.page.settle { host.page.window.attachedSheet != nil }
        #expect(holder.request?.taskID == task.taskID)
        holder.request = nil
        await host.page.settle { host.page.window.attachedSheet == nil }
        // then
        #expect(fixture.sut.isMounted)
        #expect(fixture.sut.currentTaskID == task.taskID)
        verify(fixture.useCase).cancel(.any).called(0)
    }
}

// MARK: - StateStopHolder

@Observable @MainActor private final class StateStopHolder {
    var request: TaskStopConfirmation?
}

// MARK: - StateStopMount

private struct StateStopMount: View {
    let sut: TaskDetailVM
    @Bindable var holder: StateStopHolder
    private let store = TaskPaneStateStore()

    var body: some View {
        TaskDetailView(sut, chrome: .standalone, paneBinding: .init(store: store, conversationID: "abc12345"), transcriptStyle: .transcript)
            .sheet(item: $holder.request) { request in
                TaskStopConfirmationView(confirmation: request) {
                    guard holder.request?.id == request.id else { return }
                    holder.request = nil
                    request.confirm()
                }
            }
    }
}
