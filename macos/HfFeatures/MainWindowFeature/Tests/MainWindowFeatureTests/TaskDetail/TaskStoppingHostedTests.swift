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
    @Test(arguments: [false, true], [588, 1000] as [CGFloat])
    func givenMountedDraft_whenStoppingBecomesQualified_thenNoticeAndDisabledStopPreserveDraft(dark: Bool, width: CGFloat) async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
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
                                size: CGSize(width: width, height: 700), appearance: dark ? .dark : .light)
        defer { page.close(); fixture.sut.didDisappear() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([running])
        await page.settle { page.element("Stop") != nil && MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        await MessageBoxTranscriptStyleHostedTests.type("Keep this exact draft", into: field, in: page)
        // when
        fixtures.stopping.value = true
        fixtures.stoppingSubject.send(())
        await page.settle { page.element("Stopping…") != nil && page.element("Stop requested") != nil }
        // then
        let stop = try #require(page.element("Stopping…"))
        #expect(Self.isEnabled(stop) == false)
        #expect(field.stringValue == "Keep this exact draft")
        #expect(field.window === page.window)
        let body = try #require(page.element("This run has not exited yet. The status changes when Harflow records the outcome."))
        let frame = try #require(page.frame(body))
        #expect(frame.width > 0 && frame.height > 0)
        #expect(fixture.sut.task?.status == .running)
        #expect(fixture.sut.messageBoxModel.canSend)
        #expect(fixture.sut.stateTreatment?.isLeadingNotice == true)
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let entries = try #require(table.owner?.entries)
        let notice = try #require(entries.firstIndex { if case .taskState = $0 { return true }; return false })
        for index in entries.indices { if case .row = entries[index] { #expect(notice < index) } }
        #expect(TaskBadgeModel.make(evidence: try #require(fixture.sut.snapshotEvidence), startedAt: nil).label == "Running")
        try capture(page, name: "stopping-\(Int(width))-\(dark ? "dark" : "light")")
    }

    private func capture(_ page: RedesignHost, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_STOPPING_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        page.host.layoutSubtreeIfNeeded()
        let bitmap = try #require(page.host.bitmapImageRepForCachingDisplay(in: page.host.bounds))
        page.host.cacheDisplay(in: page.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
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
