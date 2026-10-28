import AppKit
import Foundation
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized)
struct TaskContinuityTests {
    @Test
    func givenTerminalListingAndStaleRunningSnapshot_whenInspectorRecomputes_thenContinuityDoesNotClaimRunning() throws {
        // given
        let harness = TaskDetailVMTests().makeSUT()
        let running = try #require(TaskDetailViewModelMock.continuity().task)
        harness.snapshotBox.value = running
        var raw = running.raw
        raw["status"] = .string("completed")
        let terminal = try #require(TaskInfo(.object(raw)))
        // when
        harness.sut.recomputeInspector(task: terminal, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.showsContinuity == false)
        #expect(harness.sut.inspectorModel?.restartHistory.count == 1)
    }

    @Test
    func givenRepeatedAndLaterObservers_whenInspectorRecomputes_thenHistoryUsesFullIdentityAndTask() throws {
        // given
        let harness = TaskDetailVMTests().makeSUT()
        let first = try #require(TaskDetailViewModelMock.continuity().task)
        harness.snapshotBox.value = first
        // when
        harness.sut.recomputeInspector(task: first, ancestors: [], allChildren: [])
        harness.sut.recomputeInspector(task: first, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.restartHistory.count == 1)
        #expect(harness.sut.inspectorModel?.showsContinuity == true)
        // when: only the nullable observing timestamp changes
        var stampRaw = first.raw
        var stampEvidence = try #require(stampRaw["supervision"]?.objectValue)
        var stampAdoption = try #require(stampEvidence["adopted_after_restart"]?.objectValue)
        stampAdoption["at"] = .string("invalid time")
        stampEvidence["adopted_after_restart"] = .object(stampAdoption)
        stampRaw["supervision"] = .object(stampEvidence)
        let restamped = try #require(TaskInfo(.object(stampRaw)))
        harness.snapshotBox.value = restamped
        harness.sut.recomputeInspector(task: restamped, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.restartHistory.count == 1)
        // given: a reused PID with a distinct process-start identity
        var later = first.raw
        var evidence = try #require(later["supervision"]?.objectValue)
        var adoption = try #require(evidence["adopted_after_restart"]?.objectValue)
        var observing = try #require(adoption["observing_process"]?.objectValue)
        observing["start_time"] = .string("next generation")
        adoption["observing_process"] = .object(observing)
        evidence["adopted_after_restart"] = .object(adoption)
        later["supervision"] = .object(evidence)
        let next = try #require(TaskInfo(.object(later)))
        // when
        harness.snapshotBox.value = next
        harness.sut.recomputeInspector(task: next, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.restartHistory.count == 2)
        // when: healthy adoption transitions to lost capture
        let lost = try #require(TaskDetailViewModelMock.continuity(loss: true).task)
        harness.snapshotBox.value = lost
        harness.sut.recomputeInspector(task: lost, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.showsContinuity == false)
        #expect(harness.sut.inspectorModel?.notices.contains { $0.contains("Output capture stopped") } == true)
        #expect(harness.sut.inspectorModel?.restartHistory.count == 2)
        // when: completion no longer carries adoption
        var terminal = first.raw
        terminal["status"] = .string("completed")
        terminal["supervision"] = nil
        let completed = try #require(TaskInfo(.object(terminal)))
        harness.snapshotBox.value = completed
        harness.sut.recomputeInspector(task: completed, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.showsContinuity == false)
        #expect(harness.sut.inspectorModel?.restartHistory.count == 2)
        // when: a different task is selected
        terminal["task_id"] = .string("another-task")
        let other = try #require(TaskInfo(.object(terminal)))
        harness.snapshotBox.value = other
        harness.sut.recomputeInspector(task: other, ancestors: [], allChildren: [])
        // then
        #expect(harness.sut.inspectorModel?.restartHistory.isEmpty == true)
    }

    @Test
    func givenSharedSessionHistory_whenTaskIsReselectedAfterCompletion_thenRecentEvidenceRemainsTaskScoped() throws {
        // given
        let store = TaskContinuityHistoryStore()
        let first = try #require(TaskDetailViewModelMock.continuity().task)
        let observation = try #require(first.supervision?.restartObservation)
        store.record(observation, for: first.taskID)
        store.record(observation, for: first.taskID)
        // when: a new task-detail VM replaces the old selection
        let harness = TaskDetailVMTests().makeSUT()
        let replacement = TaskDetailVM(taskID: first.taskID, useCase: harness.useCase, routing: harness.routing, continuityHistory: store)
        var raw = first.raw
        raw["status"] = .string("completed")
        raw["supervision"] = nil
        let terminal = try #require(TaskInfo(.object(raw)))
        harness.snapshotBox.value = terminal
        replacement.recomputeInspector(task: terminal, ancestors: [], allChildren: [])
        // then
        #expect(replacement.inspectorModel?.restartHistory == [observation])
        #expect(replacement.inspectorModel?.showsContinuity == false)
        #expect(store.observations(for: "other-task").isEmpty)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenContinuityStates_whenHostedAtMinimumWindowSize_thenAccessibleRowAndDetailsFollowEvidence(scheme: ColorScheme) async throws {
        for state in ["running", "completed", "loss"] {
            // given
            // 1000-point supported main window minus its 240-point sidebar leaves 760 points.
            let mock = TaskDetailViewModelMock.continuity(status: state == "completed" ? "completed" : "running", loss: state == "loss")
            let host = RedesignHost(
                TaskDetailView(mock, isEmbedded: true).preferredColorScheme(scheme).environment(\.hfReduceMotionOverride, true),
                size: CGSize(width: 760, height: 620), appearance: scheme
            )
            defer { host.close() }
            NSApp.activate()
            host.window.makeKeyAndOrderFront(nil)
            // when
            await host.settle { host.element("Activity") != nil }
            // then
            #expect(host.hasRenderedInk)
            let details = host.element("Show supervision details")
            #expect((details != nil) == (state == "running"))
            #expect(mock.inspectorModel?.restartHistory.count == 1)
            #expect(mock.inspectorModel?.notices.isEmpty == (state != "loss"))
            if let details {
                // when: the same accessible button used by keyboard activation opens diagnostics
                #expect(host.press(details))
                await host.settle { host.element("Supervision") != nil }
                // then
                #expect(host.element("Supervision") != nil)
                #expect(host.element("Current observing process") != nil)
                let section = try #require(host.element("Supervision"))
                #expect(section.responds(to: NSSelectorFromString("isAccessibilityFocused")))
                await host.settle { accessibilityFocused(section) == true }
                #expect(accessibilityFocused(section) == true)
            }
            if details == nil {
                let toggle = try #require(host.element("Show inspector"))
                #expect(host.press(toggle))
                await host.settle { host.element("Technical info") != nil }
                let disclosure = try #require(host.element("Technical info"))
                #expect(host.press(disclosure))
                await host.settle { host.element("Current observing process") != nil }
                #expect(host.element("Current observing process") != nil)
            }
            let label = try #require(host.element("Current observing process"))
            let frame = try #require(host.frame(label))
            #expect(frame.width > 0 && frame.minX >= 0 && frame.maxX <= host.host.bounds.width + 1)
            if let directory = ProcessInfo.processInfo.environment["HARFLOW_CONTINUITY_CAPTURE_DIR"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try capture(host, to: root.appendingPathComponent("continuity-\(state)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// SwiftUI virtual accessibility nodes implement AX selectors without conforming to AppKit's protocol.
    private func accessibilityFocused(_ element: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityFocused")
        guard element.responds(to: selector) else { return nil }
        typealias ReadFocused = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(element.method(for: selector), to: ReadFocused.self)
        return implementation(element, selector)
    }

    private func capture(_ host: RedesignHost, to url: URL) throws {
        // given
        host.host.layoutSubtreeIfNeeded()
        host.host.displayIfNeeded()
        let bitmap = try #require(host.host.bitmapImageRepForCachingDisplay(in: host.host.bounds))
        // when
        host.host.cacheDisplay(in: host.host.bounds, to: bitmap)
        // then
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
