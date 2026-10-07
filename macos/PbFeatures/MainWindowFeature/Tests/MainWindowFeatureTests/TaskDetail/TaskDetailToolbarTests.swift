import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
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
.defaultAppStorage(defaults)))
        controller.sceneBridgingOptions = .all
        window.contentViewController = controller
        window.orderFront(nil)
    }

    func pump() {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }

    func settle() async {
        await waitUntil { pump(); return evaluations > 0 && window.toolbar?.items.isEmpty == false }
        await Task.yield()
        pump()
    }

    func close() { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
}
