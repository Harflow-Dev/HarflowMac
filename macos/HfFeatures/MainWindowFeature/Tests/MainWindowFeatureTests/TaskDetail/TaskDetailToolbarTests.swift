import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TaskDetailToolbarTests {
    @Test func givenFullTaskMetadataChanges_whenActivityUpdates_thenToolbarPresenterIsNotReevaluated() async throws {
        // given
        let fixture = TaskChromeFixture()
        defer { fixture.close() }
        await fixture.settle()
        let toolbar = try #require(fixture.window.toolbar)
        #expect(!toolbar.items.isEmpty)
        let baseline = fixture.evaluations
        let itemIDs = toolbar.items.map(ObjectIdentifier.init)
        let viewIDs = toolbar.items.compactMap { $0.view.map(ObjectIdentifier.init) }
        #expect(!viewIDs.isEmpty)
        // when: the actual TaskDetail VM publishes new task metadata, not just a synthetic counter.
        for revision in 1 ... 5 {
            var raw = try #require(fixture.harness.sut.task?.raw)
            raw["summary"] = .string("Activity revision \(revision)")
            raw["num_turns"] = .number(Double(revision))
            fixture.harness.detailBox.value = TaskInfo(.object(raw))
            fixture.harness.tasksSubject.send([try #require(fixture.harness.detailBox.value)])
            await waitUntil { fixture.harness.sut.task?.summary == "Activity revision \(revision)" }
            fixture.pump()
        }
        let itemsStable = itemIDs == toolbar.items.map(ObjectIdentifier.init)
        let viewsStable = viewIDs == toolbar.items.compactMap { $0.view.map(ObjectIdentifier.init) }
        let delta = fixture.evaluations - baseline
        print("Activity-only changes: toolbar evaluations \(delta), stable items/views \(itemsStable)/\(viewsStable)")
        // then
        fixture.harness.itemsSubject.send([PreviewFixtures.textItem("New streamed output")])
        await waitUntil { fixture.harness.sut.timelineModel.rows.count == 1 }
        fixture.harness.sut.didSelectTab(.summary)
        fixture.pump()
        #expect(fixture.evaluations == baseline)
        #expect(itemIDs == toolbar.items.map(ObjectIdentifier.init))
        #expect(viewIDs == toolbar.items.compactMap { $0.view.map(ObjectIdentifier.init) })
    }

    @Test func givenToolbar_whenStatusBusyAndInspectorChange_thenPresenterRefreshesAndActionsRemainAvailable() async throws {
        // given
        let fixture = TaskChromeFixture()
        defer { fixture.close() }
        await fixture.settle()
        var baseline = fixture.evaluations
        var raw = try #require(fixture.harness.sut.task?.raw)
        // when
        raw["status"] = .string("completed")
        fixture.harness.detailBox.value = TaskInfo(.object(raw))
        fixture.harness.tasksSubject.send([try #require(fixture.harness.detailBox.value)])
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }
        // then
        #expect(fixture.harness.sut.task?.status == .completed)
        #expect(!fixture.harness.sut.canCancel)
        #expect(fixture.window.toolbar?.items.compactMap(\.view).isEmpty == false)
        // when
        baseline = fixture.evaluations
        fixture.harness.busySubject.send(["abc12345"])
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }
        #expect(fixture.harness.sut.isBusy)
        // when
        baseline = fixture.evaluations
        fixture.defaults.set(true, forKey: "monitor.inspectorVisible")
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }
        // then
        #expect(fixture.defaults.bool(forKey: "monitor.inspectorVisible"))
        #expect(fixture.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "task-detail.inspector" }?.view != nil)
    }

}

@MainActor private final class TaskChromeFixture {
    let harness = TaskDetailVMTests().makeSUT()
    var evaluations = 0
    var controller: NSHostingController<AnyView>!
    let window: NSWindow
    let defaults = UserDefaults(suiteName: "TaskChromeFixture-\(UUID().uuidString)")!
    init() {
        _ = NSApplication.shared
        var raw = TaskDetailVMTests().task().raw
        raw["started_at"] = .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90)))
        harness.detailBox.value = TaskInfo(.object(raw))
        self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.controller = NSHostingController(rootView: AnyView(NavigationStack {
            TaskDetailView(harness.sut, onToolbarEvaluation: { [weak self] in self?.evaluations += 1 })
        }
.withPresentationContext()
.defaultAppStorage(defaults)
.environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        window.contentViewController = controller
        window.orderFront(nil)
    }

    func pump() {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }

    func settle() async {
        await waitUntil(timeout: 5) {
            pump()
            return harness.sut.task != nil
                && harness.sut.didSubscribe
                && !harness.sut.conversationLoading
                && harness.sut.conversationHistoryResolved
        }
        #expect(harness.sut.task != nil && harness.sut.didSubscribe
            && !harness.sut.conversationLoading && harness.sut.conversationHistoryResolved,
            "Task detail must finish initial model and history loading before taking the toolbar baseline")
        if let acquisition = harness.sut.memberLeaseAcquisition { await acquisition.value }
        await waitUntil(timeout: 5) {
            pump()
            return harness.sut.timelineWorker == nil && harness.sut.pendingTimelineInput == nil
        }
        #expect(harness.sut.timelineWorker == nil && harness.sut.pendingTimelineInput == nil,
                "Initial timeline presentation must settle before taking the toolbar baseline")

        var previousReport: ToolbarReport?
        var consecutiveStableReports = 0
        await waitUntil(timeout: 5) {
            pump()
            let report = toolbarReport
            if report == previousReport {
                consecutiveStableReports += 1
            } else {
                previousReport = report
                consecutiveStableReports = 1
            }
            return report.evaluations > 0 && !report.itemIDs.isEmpty && !report.viewIDs.isEmpty && consecutiveStableReports >= 3
        }
        let report = toolbarReport
        #expect(report.evaluations > 0 && !report.itemIDs.isEmpty && !report.viewIDs.isEmpty && consecutiveStableReports >= 3,
                "A populated native toolbar must stabilize before taking the baseline")
    }

    private var toolbarReport: ToolbarReport {
        let items = window.toolbar?.items ?? []
        return ToolbarReport(evaluations: evaluations,
                             itemIDs: items.map(ObjectIdentifier.init),
                             viewIDs: items.compactMap { $0.view.map(ObjectIdentifier.init) })
    }

    private struct ToolbarReport: Equatable {
        let evaluations: Int
        let itemIDs: [ObjectIdentifier]
        let viewIDs: [ObjectIdentifier]
    }

    func close() { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
}
