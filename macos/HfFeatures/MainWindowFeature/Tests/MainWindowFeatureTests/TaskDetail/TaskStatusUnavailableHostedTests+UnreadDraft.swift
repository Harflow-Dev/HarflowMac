import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStatusUnavailableHostedTests + UnreadDraft

extension TaskStatusUnavailableHostedTests {
    @Test func givenUnreadStatus_whenDraftIsTypedAndFirstReadSucceeds_thenDraftRemainsAndSendBecomesEnabled() async throws {
        // given — retained display data alone does not authorize commands.
        let fixtures = TaskDetailVMTests.Fixtures()
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        let running = try #require(TaskInfo(.object([
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string("running"),
            "live_input": .bool(true), "session_id": .string("fixture-session"),
            "supervision": .object(["owner_state": .string("alive")])
        ])))
        fixture.detailBox.value = running
        fixture.snapshotBox.value = running
        let outcome = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(nil)
        fixtures.statusReadProvider.value = { _ in outcome.value }
        let panes = TaskPaneStateStore()
        panes.setOpenChoice(.closed, for: "abc12345")
        let page = RedesignHost(UnreadDraftHarness(sut: fixture.sut, paneBinding: .init(store: panes, conversationID: "abc12345")),
                                size: CGSize(width: 1000, height: 700))
        defer { page.close(); fixture.sut.didDisappear() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([running])
        await page.settle { MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil && page.element("Send") != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        #expect(field.isEnabled && field.isEditable)
        #expect(!fixture.sut.hasStatusAuthority && !fixture.sut.isStatusUnavailable)
        #expect(page.element("Current status unavailable") == nil)
        #expect(page.element("Stop") == nil)
        let send = try #require(page.element("Send"))
        #expect(TaskStoppingHostedTests.isEnabled(send) == false)

        // when — type through the native editor while the first read is still unadmitted.
        await MessageBoxTranscriptStyleHostedTests.type("Draft before the first status read", into: field, in: page)

        // then — typing is allowed, while a populated draft still cannot send a command.
        #expect(field.stringValue == "Draft before the first status read")
        #expect(TaskStoppingHostedTests.isEnabled(send) == false)
        #expect(!fixture.sut.messageBoxModel.canSend)

        // when — the first successful status read emits its own invalidation, without a display snapshot change.
        outcome.value = .init(revision: 1, task: running)
        fixtures.statusReadSubject.send(())
        await page.settle {
            guard let currentSend = page.element("Send") else { return false }
            return fixture.sut.hasStatusAuthority && TaskStoppingHostedTests.isEnabled(currentSend) == true
        }

        // then
        let recoveredField = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        #expect(recoveredField === field)
        #expect(recoveredField.stringValue == "Draft before the first status read")
        #expect(fixture.sut.messageBoxModel.canSend)
        let recoveredSend = try #require(page.element("Send"))
        #expect(TaskStoppingHostedTests.isEnabled(recoveredSend) == true)
        #expect(page.element("Current status unavailable") == nil)
    }
}

private struct UnreadDraftHarness: View {
    @State var sut: TaskDetailVM
    let paneBinding: TaskPaneBinding
    var body: some View {
        TaskDetailView(sut, chrome: .standalone, paneBinding: paneBinding, transcriptStyle: .transcript)
    }
}
