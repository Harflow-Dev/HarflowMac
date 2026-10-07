import AppKit
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TaskDetailToolbarSnapshotTests {
    @Test func givenSamePresentation_whenMetadataChanges_thenSnapshotIgnoresActivityButTracksEveryChromeField() throws {
        // given
        let vm = TaskDetailViewModelMock()
        let task = try #require(vm.task)
        let baseline = TaskDetailToolbarSnapshot(vm, task: task, showsInspector: false)
        var raw = task.raw
        raw["summary"] = .string("New activity")
        raw["usage"] = .object(["output_tokens": .number(900)])
        raw["num_turns"] = .number(7)
        #expect(baseline == TaskDetailToolbarSnapshot(vm, task: try #require(TaskInfo(.object(raw))), showsInspector: false))
        // when / then
        for (key, value) in ["task_id": JSONValue.string("resumed"), "status": .string("completed"),
                             "started_at": .string("2026-10-07T00:00:00Z"), "duration_seconds": .number(42), "taken_over": .bool(true)] {
            var changed = task.raw
            changed[key] = value
            #expect(baseline != TaskDetailToolbarSnapshot(vm, task: try #require(TaskInfo(.object(changed))), showsInspector: false))
        }
        #expect(baseline != TaskDetailToolbarSnapshot(vm, task: task, showsInspector: true))
        let mutations: [(TaskDetailViewModelMock) -> Void] = [
            { $0.isBusy = true }, { $0.canTakeover = false }, { $0.takeoverButtonLabel = "Resume here" },
            { $0.takeoverHelp = "Changed help" }, { $0.canCancel = false }, { $0.resumeCommand = nil },
            { $0.openParentTaskID = "parent" },
            { $0.task = TaskInfo(.object(["task_id": .string("native"), "execution_kind": .string("native_subagent")])) }
        ]
        for mutation in mutations {
            let owner = TaskDetailViewModelMock()
            owner.task = task
            let original = TaskDetailToolbarSnapshot(owner, task: task, showsInspector: false)
            mutation(owner)
            #expect(original != TaskDetailToolbarSnapshot(owner, task: task, showsInspector: false))
        }
    }

    @Test func givenNativeToolbar_whenOwnerOrTaskIdentityChanges_thenPresenterInstallsCurrentActionOwner() async throws {
        // given
        let state = ToolbarOwnerState()
        let controller = NSHostingController(rootView: ToolbarOwnerView(state: state))
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        await waitUntil { window.layoutIfNeeded(); return state.evaluations > 0 && window.toolbar?.items.isEmpty == false }
        let originalOwner = ObjectIdentifier(state.owner)
        state.latestAction?()
        #expect(state.invokedOwners == [originalOwner])
        // when: identical chrome with a different VM must replace its action closures.
        let newOwner = TaskDetailViewModelMock()
        newOwner.task = state.owner.task
        var baseline = state.evaluations
        state.owner = newOwner
        await waitUntil { window.layoutIfNeeded(); return state.evaluations > baseline }
        state.latestAction?()
        // then
        #expect(state.invokedOwners.last == ObjectIdentifier(newOwner))
        #expect(state.invokedOwners.last != originalOwner)
        // when
        baseline = state.evaluations
        var raw = try #require(state.owner.task?.raw)
        raw["task_id"] = .string("resumed-task")
        state.owner.task = TaskInfo(.object(raw))
        state.revision += 1
        await waitUntil { window.layoutIfNeeded(); return state.evaluations > baseline }
        // then
        #expect(state.latestTaskID == "resumed-task")
    }
}

@MainActor @Observable private final class ToolbarOwnerState {
    var owner = TaskDetailViewModelMock()
    var revision = 0
    @ObservationIgnored var evaluations = 0
    @ObservationIgnored var latestAction: (() -> Void)?
    @ObservationIgnored var latestTaskID: String?
    @ObservationIgnored var invokedOwners: [ObjectIdentifier] = []
}

private struct ToolbarOwnerView: View {
    let state: ToolbarOwnerState
    var body: some View {
        let owner = state.owner
        let task = owner.task ?? TaskDetailViewModelMock.sampleTask()
        let snapshot = TaskDetailToolbarSnapshot(owner, task: task, showsInspector: false)
        let actions = TaskDetailToolbarActions(
            takeover: { state.invokedOwners.append(ObjectIdentifier(owner)) }, cancel: {}, copyResumeCommand: {},
            openTask: { _ in }, showRawEvents: {}, toggleInspector: {}
        )
        Text("Activity revision \(state.revision)")
.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                TaskDetailToolbar(snapshot: snapshot, actions: actions, onEvaluation: {
                    state.evaluations += 1
                    state.latestAction = actions.takeover
                    state.latestTaskID = snapshot.statusTask.taskID
                }).equatable()
            }
    }
}
