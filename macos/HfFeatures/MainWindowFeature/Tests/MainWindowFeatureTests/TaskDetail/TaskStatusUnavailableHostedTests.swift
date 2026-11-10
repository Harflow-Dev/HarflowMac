import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStatusUnavailableHostedTests

@MainActor @Suite(.serialized) struct TaskStatusUnavailableHostedTests {
    static let body = "The engine did not answer. Everything below was read earlier and may be out of date."

    @Test(arguments: [false, true], [588, 1000] as [CGFloat])
    func givenMountedDraft_whenStatusFailsAndRetryRecoversEquivalentSnapshot_thenNoticeLocksAndRestoresDraft(dark: Bool, width: CGFloat) async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        let running = try #require(TaskInfo(.object([
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string("running"),
            "live_input": .bool(true), "session_id": .string("fixture-session"),
            "supervision": .object(["owner_state": .string("alive")])
        ])))
        fixture.detailBox.value = running
        fixture.snapshotBox.value = running
        let outcome = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: running))
        fixtures.statusReadProvider.value = { _ in outcome.value }
        let retries = TaskDetailVMTests.Box(0)
        fixtures.refreshSnapshotEffect.value = {
            retries.value += 1
            outcome.value = .init(revision: 3, task: running)
            fixtures.statusReadSubject.send(())
        }
        let panes = TaskPaneStateStore()
        panes.setOpenChoice(.closed, for: "abc12345")
        let page = RedesignHost(UnavailableTaskHarness(sut: fixture.sut, paneBinding: .init(store: panes, conversationID: "abc12345"))
            .preferredColorScheme(dark ? .dark : .light), size: CGSize(width: width, height: 700), appearance: dark ? .dark : .light)
        defer { page.close(); fixture.sut.didDisappear() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([running])
        await page.settle { MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        await MessageBoxTranscriptStyleHostedTests.type("Keep this exact draft", into: field, in: page)
        let readCount = retries.value
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)

        // when — only the read outcome changes; the retained task snapshot stays byte-equivalent.
        outcome.value = .init(revision: 2, task: nil)
        fixtures.statusReadSubject.send(())
        await page.settle { fixture.sut.isStatusUnavailable && page.element("Current status unavailable") != nil }

        // then
        #expect(!fixture.sut.hasStatusAuthority && fixture.sut.task == running)
        #expect(fixture.sut.messageBoxModel.isLocked && !fixture.sut.messageBoxModel.canSend && !fixture.sut.messageBoxModel.canContinue)
        #expect(fixture.sut.messageBoxModel.placeholder == "Unavailable until status can be read")
        #expect(fixture.sut.messageBoxModel.hint.isEmpty)
        #expect(fixture.sut.topBarContent?.badge == .statusUnavailable)
        #expect(page.element("Stop") == nil)
        let entries = try #require(table.owner?.entries)
        let notice = try #require(entries.firstIndex { if case .taskState = $0 { return true }; return false })
        for index in entries.indices { if case .row = entries[index] { #expect(notice < index) } }
        let retry = try #require(page.element("Retry read"))
        #expect(TaskStoppingHostedTests.isEnabled(retry) == true)
        let retryFrame = try #require(page.frame(retry))
        let titleElement = try #require(page.element("Current status unavailable"))
        let titleFrame = try #require(page.frame(titleElement))
        #expect(retryFrame.minX > titleFrame.maxX)
        #expect(page.element(Self.body) != nil)
        try capture(page, name: "unavailable-\(Int(width))-\(dark ? "dark" : "light")")

        // when — activate the rendered read action, without emitting a snapshot change.
        #expect(page.press(retry))
        await page.settle { !fixture.sut.isStatusUnavailable && MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }

        // then — the mounted composer preserves its local draft across the lock.
        #expect(retries.value == readCount + 1)
        #expect(fixture.sut.hasStatusAuthority)
        #expect(!fixture.sut.messageBoxModel.isLocked && fixture.sut.messageBoxModel.canSend)
        #expect(page.element("Current status unavailable") == nil)
        let recoveredField = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        #expect(recoveredField.stringValue == "Keep this exact draft")
        #expect(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first === table)
    }

    @Test(arguments: [false, true])
    func givenNarrowUnavailableNotice_whenHosted_thenBodyWrapsAndRetryRemainsAtOuterRight(dark: Bool) async throws {
        // given
        let model = TaskStateTreatment(taskID: "t1", kind: .statusUnavailable)
        let page = RedesignHost(TaskStateTreatmentView(model: model).frame(width: 320).preferredColorScheme(dark ? .dark : .light),
                                size: CGSize(width: 320, height: 240), appearance: dark ? .dark : .light)
        defer { page.close() }
        // when
        await page.settle { page.element(Self.body) != nil }
        // then
        let noticeElement = try #require(page.element("task-state-statusUnavailable"))
        let notice = try #require(page.frame(noticeElement))
        let bodyElement = try #require(page.element(Self.body))
        let body = try #require(page.frame(bodyElement))
        let titleElement = try #require(page.element("Current status unavailable"))
        let title = try #require(page.frame(titleElement))
        let retryElement = try #require(page.element("Retry read"))
        let retry = try #require(page.frame(retryElement))
        #expect(abs(notice.width - 320) < 1)
        #expect(body.height > 20)
        #expect(notice.contains(body) && notice.contains(title) && notice.contains(retry))
        #expect(retry.minX > title.maxX)
        #expect(body.maxY <= title.minY)
        try capture(page, name: "unavailable-component-320-\(dark ? "dark" : "light")")
    }

    private func capture(_ page: RedesignHost, name: String) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/harflow-mac-unavailable", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        page.host.layoutSubtreeIfNeeded()
        let bitmap = try #require(page.host.bitmapImageRepForCachingDisplay(in: page.host.bounds))
        page.host.cacheDisplay(in: page.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

private struct UnavailableTaskHarness: View {
    @State var sut: TaskDetailVM
    let paneBinding: TaskPaneBinding
    var body: some View {
        TaskDetailView(sut, chrome: .standalone, paneBinding: paneBinding, transcriptStyle: .transcript)
    }
}
