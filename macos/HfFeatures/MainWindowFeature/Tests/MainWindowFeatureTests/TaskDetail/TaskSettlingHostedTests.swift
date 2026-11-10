import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskSettlingHostedTests

/// The notice is driven by the mounted VM's real observation and Changes admission paths.
@MainActor @Suite(.serialized) struct TaskSettlingHostedTests {
    static let body = "The run finished. Its last events and stored changes may still arrive."

    @Test(arguments: [false, true], [588, 1000] as [CGFloat])
    func givenMountedCompletedRun_whenBothReadsSettle_thenLeadingNoticePreservesDoneAndDraft(dark: Bool, width: CGFloat) async throws {
        // given — the observation is current without claiming that history is caught up or drained.
        let fixture = TaskDetailVMTests().makeSUT(taskID: "t1", chrome: .standalone)
        let task = SummaryEntryScenario.info(status: "completed", fields: ["exit_code": .number(0), "session_id": .string("fixture-session")])
        fixture.detailBox.value = task
        fixture.snapshotBox.value = task
        let script = ChangesReadScript(.snapshot(try ChangesJSON.captureOnly(task: "t1", state: "pending", reason: "capture_settling")))
        given(fixture.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
        let paneStore = TaskPaneStateStore()
        paneStore.setOpenChoice(.closed, for: "t1")
        let harness = SettlingTaskHarness(sut: fixture.sut, paneBinding: .init(store: paneStore, conversationID: "t1"))
        let page = RedesignHost(harness.preferredColorScheme(dark ? .dark : .light),
                                size: CGSize(width: width, height: 700), appearance: dark ? .dark : .light)
        defer { page.close(); fixture.sut.didDisappear() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([task])
        await page.settle { MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        await MessageBoxTranscriptStyleHostedTests.type("Keep the next turn draft", into: field, in: page)
        let composer = fixture.sut.messageBoxModel
        #expect(!fixture.sut.isSettling)
        #expect(page.element("Settling") == nil)
        #expect(script.calls.isEmpty)

        // when — event evidence supplies demand, and only the admitted Changes reply qualifies the notice.
        script.whileInFlight(script.count) {
            #expect(!fixture.sut.isSettling)
            #expect(fixture.sut.stateTreatment == nil)
        }
        publish(frame(), to: fixture)
        await page.settle { fixture.sut.isSettling && page.element("Settling") != nil }

        // then
        #expect(!script.calls.isEmpty)
        #expect(fixture.sut.stateTreatment?.isLeadingNotice == true)
        let body = try #require(page.element(Self.body))
        let bodyFrame = try #require(page.frame(body))
        #expect(bodyFrame.width > 0 && bodyFrame.height > 0)
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let entries = try #require(table.owner?.entries)
        let notice = try #require(entries.firstIndex { if case .taskState = $0 { return true }; return false })
        for index in entries.indices { if case .row = entries[index] { #expect(notice < index) } }
        let cell = try #require(table.view(atColumn: 0, row: notice, makeIfNecessary: true) as? ActivityFeedNativeCell)
        let root = try #require(cell.host)
        #expect(abs(root.fittingSize.height - table.rect(ofRow: notice).height) < 3)
        let scroll = try #require(table.enclosingScrollView)
        let column = scroll.convert(scroll.bounds, to: nil)
        #expect(bodyFrame.minX >= column.minX && bodyFrame.maxX <= column.maxX)
        #expect(TaskBadgeModel.make(evidence: try #require(fixture.sut.snapshotEvidence), startedAt: nil).label == "Done")
        #expect(fixture.sut.messageBoxModel.canSend == composer.canSend)
        #expect(fixture.sut.messageBoxModel.canContinue == composer.canContinue)
        #expect(fixture.sut.messageBoxModel.isBusy == composer.isBusy)
        #expect(fixture.sut.messageBoxModel.buttonLabel == composer.buttonLabel)
        #expect(fixture.sut.messageBoxModel.hint == composer.hint)
        #expect(field.stringValue == "Keep the next turn draft" && field.window === page.window)
        try capture(page, name: "settling-\(Int(width))-\(dark ? "dark" : "light")")
    }

    @Test(arguments: [false, true])
    func givenNarrowNoticeComponent_whenHostedAtMeasuredWidth_thenExactCopyWrapsWithoutClipping(dark: Bool) async throws {
        // given — isolate the notice from the composer's larger intrinsic minimum width.
        let model = TaskStateTreatment(taskID: "t1", kind: .settling, isStopDisabled: false, showsCopyResumeCommand: false)
        let view = TaskStateTreatmentView(model: model)
.frame(width: 320)
            .preferredColorScheme(dark ? .dark : .light)
        let page = RedesignHost(view, size: CGSize(width: 320, height: 180), appearance: dark ? .dark : .light)
        defer { page.close() }
        // when
        await page.settle { page.element(Self.body) != nil }
        // then — check rendered component geometry rather than the requested window size.
        let notice = try #require(page.element("task-state-settling"))
        let noticeFrame = try #require(page.frame(notice))
        let body = try #require(page.element(Self.body))
        let bodyFrame = try #require(page.frame(body))
        let title = try #require(page.element("Settling"))
        let titleFrame = try #require(page.frame(title))
        #expect(abs(noticeFrame.width - 320) < 1)
        #expect(bodyFrame.height > 20)
        #expect(noticeFrame.contains(bodyFrame))
        #expect(noticeFrame.contains(titleFrame))
        #expect(bodyFrame.maxY <= titleFrame.minY)
        try capture(page, name: "settling-component-320-\(dark ? "dark" : "light")")
    }

    @Test(arguments: [EventObservationCurrentness.reconnecting, .sourceChangePending, .current])
    func givenRetainedSettlingFeed_whenEvidenceStopsQualifying_thenNoticeDisappearsWithoutReplacingFeed(currentness: EventObservationCurrentness) async throws {
        // given
        let fixture = TaskDetailVMTests().makeSUT(taskID: "t1", chrome: .standalone)
        let task = SummaryEntryScenario.info(status: "completed", fields: ["exit_code": .number(0), "session_id": .string("fixture-session")])
        fixture.detailBox.value = task
        fixture.snapshotBox.value = task
        fixture.observationBox.value = frame()
        let script = ChangesReadScript(.snapshot(try ChangesJSON.captureOnly(task: "t1", state: "pending", reason: "capture_settling")))
        given(fixture.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
        let page = RedesignHost(SettlingTaskHarness(sut: fixture.sut), size: CGSize(width: 1000, height: 700))
        defer { page.close(); fixture.sut.didDisappear() }
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([task])
        await page.settle { fixture.sut.isSettling && page.element("Settling") != nil }
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let owner = try #require(table.owner)
        let rows = owner.entries.compactMap { entry -> String? in if case .row = entry { return entry.id }; return nil }

        // when — a second read must discard the old notice qualification before returning a pending result.
        let nextRead = script.count
        script.whileInFlight(nextRead) {
            #expect(!fixture.sut.isSettling)
            #expect(fixture.sut.stateTreatment == nil)
        }
        fixture.sut.didTapRetryChanges()
        await page.settle { script.count > nextRead && fixture.sut.isSettling }
        publish(frame(currentness: currentness, log: currentness == .current ? .final : .settling), to: fixture)
        await page.settle { !fixture.sut.isSettling && page.element("Settling") == nil }

        // then — the same native table and activity rows survive the notice removal.
        #expect(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first === table)
        #expect(table.owner === owner)
        #expect(owner.entries.allSatisfy { if case .taskState = $0 { return false }; return true })
        #expect(owner.entries.compactMap { entry -> String? in if case .row = entry { return entry.id }; return nil } == rows)
        #expect(page.element(Self.body) == nil)
        #expect(TaskBadgeModel.make(evidence: try #require(fixture.sut.snapshotEvidence), startedAt: nil).label == "Done")
    }

    private func frame(currentness: EventObservationCurrentness = .current, log: EventLogState = .settling) -> EventObservationFrame {
        EventObservationFrame(taskID: "t1", scope: FeatureObservationFixture.scope,
            items: [SummaryEntryScenario.text(1, "Captured activity stays readable.")],
            history: .init(caughtUp: false, forwardDrained: false, currentness: currentness), logState: log)
    }

    private func publish(_ frame: EventObservationFrame, to fixture: TaskDetailVMTests.SUT) {
        fixture.observationBox.value = frame
        fixture.observationSubject.send(frame)
    }

    private func capture(_ page: RedesignHost, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_SETTLING_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        page.host.layoutSubtreeIfNeeded()
        let bitmap = try #require(page.host.bitmapImageRepForCachingDisplay(in: page.host.bounds))
        page.host.cacheDisplay(in: page.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

private struct SettlingTaskHarness: View {
    @State var sut: TaskDetailVM
    var paneBinding: TaskPaneBinding?
    var body: some View {
        TaskDetailView(sut, chrome: .standalone, paneBinding: paneBinding, transcriptStyle: .transcript)
    }
}
