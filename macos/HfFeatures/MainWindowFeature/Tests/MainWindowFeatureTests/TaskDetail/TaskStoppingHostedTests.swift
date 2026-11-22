import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStoppingHostedTests

@MainActor @Suite(.serialized) struct TaskStoppingHostedTests {
    @Test(arguments: [false, true], [CGSize(width: 588, height: 700), CGSize(width: 1000, height: 620), CGSize(width: 1400, height: 800)])
    func givenMountedDraft_whenStoppingBecomesQualified_thenNoticeAndDisabledStopPreserveDraft(dark: Bool, size: CGSize) async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        fixture.useCase.configureTypedSendSuccess()
        let running = TaskInfo(.object(["task_id": .string("abc12345"), "backend": .string("claude"),
            "status": .string("running"), "live_input": .bool(true),
            "supervision": .object(["owner_state": .string("alive")])]))!
        fixture.detailBox.value = running
        fixture.snapshotBox.value = running
        if case .item(let item) = ActivityFixture.text(1, "Captured activity stays readable", task: "abc12345").kind {
            fixture.itemsOverride.value = [item]
        }
        given(fixture.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .failed(.notFound(tool: "fixture changes", searched: []))))
        }
        let page = RedesignHost(StoppingTaskHarness(sut: fixture.sut).preferredColorScheme(dark ? .dark : .light),
                                size: size, appearance: dark ? .dark : .light)
        defer { page.close(); fixture.sut.didDisappear() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([running])
        await page.settle { page.element("Stop task") != nil && MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        #expect(page.element("Send now") == nil)
        #expect(page.elements(in: page.host).filter { page.matches($0, "Stop task") }.count == 1)
        let stopSlotWidth = try slotWidth("Stop task", page: page)
        try await verifyEmptyAndWhitespaceInputDoesNotStopOrSend(field, page: page, fixture: fixture)
        try await capture(page, size: size, dark: dark, state: "running-empty")
        await MessageBoxTranscriptStyleHostedTests.type("Keep this exact draft", into: field, in: page)
        await page.settle { page.element("Send now") != nil && page.element("Send") != nil }
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: page) === field)
        #expect(abs(try slotWidth("Send", page: page) - stopSlotWidth) < 0.5)
        try await verifyBusyDraftKeepsSendMode(field, page: page, fixture: fixture, stopSlotWidth: stopSlotWidth)
        try await capture(page, size: size, dark: dark, state: "running-draft")
        try await verifyPositiveQueueSend(field, page: page, fixture: fixture)
        await MessageBoxTranscriptStyleHostedTests.type("Keep this exact draft", into: field, in: page)
        fixtures.stopping.value = true
        fixtures.stoppingSubject.send(())
        await page.settle { page.element("Stopping…") != nil && page.element("Stop requested") != nil }
        try await verifyStopping(field, page: page, fixture: fixture, appearance: (size, dark),
                                 stopSlotWidth: stopSlotWidth)
    }

    private func verifyPositiveQueueSend(_ field: NSTextField, page: RedesignHost,
                                         fixture: TaskDetailVMTests.SUT) async throws {
        var dispatched = false
        when(fixture.useCase)
.submitTypedMessage(.any, text: .any, now: .value(false),
            acknowledgingUnconfirmed: .any, context: .any)
.perform { dispatched = true }
        try sendReturn(page, command: true)
        await page.settle { dispatched }
        verify(fixture.useCase)
.submitTypedMessage(.any, text: .any, now: .value(false),
            acknowledgingUnconfirmed: .any, context: .any)
.called(1)
        #expect(fixture.sut.messageBoxModel.isRunning)
        #expect(fixture.sut.messageBoxModel.showsSendNow)
        await MessageBoxTranscriptStyleHostedTests.type("", into: field, in: page)
        await page.settle { page.element("Send now") == nil && page.element("Stop task") != nil }
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: page) === field)
    }

    private func verifyStopping(_ field: NSTextField, page: RedesignHost, fixture: TaskDetailVMTests.SUT,
                                appearance: (CGSize, Bool), stopSlotWidth: CGFloat) async throws {
        let stop = try #require(page.element("Stopping…"))
        #expect(Self.isEnabled(stop) == false)
        #expect(abs(try #require(page.frame(stop)).width - stopSlotWidth) < 0.5)
        #expect(Self.isEnabled(field) == false)
        #expect(field.stringValue == "Keep this exact draft")
        #expect(field.window === page.window)
        let body = try #require(page.element("This run has not exited yet. The status changes when Harflow records the outcome."))
        let frame = try #require(page.frame(body))
        #expect(frame.width > 0 && frame.height > 0)
        #expect(fixture.sut.task?.status == .running)
        #expect(!fixture.sut.messageBoxModel.canSend)
        try sendReturn(page, command: false)
        try sendReturn(page, command: true)
        await page.settle { true }
        fixture.sut.submitMessage("Keep this exact draft")
        await page.settle { true }
        verify(fixture.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
            acknowledgingUnconfirmed: .any, context: .any)
.called(1)
        verify(fixture.routing).presentStopConfirmation(.any).called(0)
        #expect(page.element("Send now") == nil)
        #expect(fixture.sut.stateTreatment?.isLeadingNotice == true)
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let entries = try #require(table.owner?.entries)
        let notice = try #require(entries.firstIndex { if case .taskState = $0 { return true }; return false })
        for index in entries.indices { if case .row = entries[index] { #expect(notice < index) } }
        #expect(TaskBadgeModel.make(evidence: try #require(fixture.sut.snapshotEvidence), startedAt: nil).label == "Running")
        try await capture(page, size: appearance.0, dark: appearance.1, state: "stopping")
    }

    private func verifyEmptyAndWhitespaceInputDoesNotStopOrSend(
        _ field: NSTextField,
        page: RedesignHost,
        fixture: TaskDetailVMTests.SUT
    ) async throws {
        #expect(field.stringValue.isEmpty)
        #expect(page.window.makeFirstResponder(field))
        try sendReturn(page, command: false)
        try sendReturn(page, command: true)
        await page.settle { true }
        #expect(page.element("Stop task") != nil)
        verify(fixture.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
            acknowledgingUnconfirmed: .any, context: .any)
.called(0)
        verify(fixture.routing).presentStopConfirmation(.any).called(0)
        await MessageBoxTranscriptStyleHostedTests.type(" \t ", into: field, in: page)
        #expect(page.element("Stop task") != nil)
        try sendReturn(page, command: false)
        try sendReturn(page, command: true)
        await page.settle { true }
        #expect(page.element("Stop task") != nil)
        verify(fixture.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
            acknowledgingUnconfirmed: .any, context: .any)
.called(0)
        verify(fixture.routing).presentStopConfirmation(.any).called(0)
        await MessageBoxTranscriptStyleHostedTests.type("", into: field, in: page)
    }

    private func verifyBusyDraftKeepsSendMode(
        _ field: NSTextField,
        page: RedesignHost,
        fixture: TaskDetailVMTests.SUT,
        stopSlotWidth: CGFloat
    ) async throws {
        fixture.busySubject.send(["abc12345"])
        await page.settle { page.element("Send").map { Self.isEnabled($0) == false } ?? false }
        #expect(page.element("Stop task") == nil)
        #expect(page.element("Send now") != nil)
        #expect(page.element("Send now").map { Self.isEnabled($0) == false } ?? false)
        #expect(abs(try slotWidth("Send", page: page) - stopSlotWidth) < 0.5)
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: page) === field)
        fixture.busySubject.send([])
        await page.settle { page.element("Send").map { Self.isEnabled($0) == true } ?? false }
    }

    private func slotWidth(_ label: String, page: RedesignHost) throws -> CGFloat {
        let slot = try #require(page.element(label))
        return try #require(page.frame(slot)).width
    }

    private func capture(_ page: RedesignHost, size: CGSize, dark: Bool, state: String) async throws {
        guard size.width > 588,
              let directory = HostedCaptureEvidence.directory("HARFLOW_RUNNING_COMPOSER_CAPTURE_DIR") else { return }
        await HostedCaptureEvidence.prepare(page.window, dark: dark)
        let routeBase = switch state {
        case "running-empty": "task/running-composer-empty"
        default: "task/running-composer-draft"
        }
        let route = size.width == 1000 ? "\(routeBase)-minimum" : routeBase
        let design = HostedCaptureEvidence.Design(
            route: route,
            file: "v2/docs/decisions/task-detail-and-workflow-approvals.md",
            commit: "5539168eee43429edc2267f2a9402daf5f9a2d15"
        )
        let subject = HostedCaptureEvidence.Subject(suite: "running-composer", state: state, dark: dark,
                                                     size: size, design: design)
        try await HostedCaptureEvidence.record(directory: directory, subject: subject,
                                               window: page.window, host: page.host)
    }

    private func sendReturn(_ page: RedesignHost, command: Bool) throws {
        let characters = "\r"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: page.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 36))
        NSApp.sendEvent(event)
    }

    static func isEnabled(_ object: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return getter(object, selector)
    }
}

private struct StoppingTaskHarness: View {
    @State var sut: TaskDetailVM
    var body: some View {
        TaskDetailView(sut, chrome: .standalone, transcriptStyle: .transcript)
    }
}
