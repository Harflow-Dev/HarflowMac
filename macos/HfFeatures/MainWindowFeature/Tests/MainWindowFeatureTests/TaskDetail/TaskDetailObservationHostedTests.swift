import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TaskDetailObservationHostedTests {
    @Test(arguments: [ColorScheme.light, .dark], [1000.0, 1280.0])
    func givenPublicObservation_whenActualTaskDetailHosted_thenExpandedRequestAndEventsRemainUsable(scheme: ColorScheme, width: Double) async throws {
        // given — actual TaskDetail composition with synthetic public reads; no engine or sidebar.
        let model = TaskDetailViewModelMock()
        try seedScrollableObservation(model)
        let height = width == 1000 ? 620.0 : 800.0
        let detailWidth = width - 256 // Reserve the canonical sidebar width from the app reference.
        let fixture = ObservationHost(NavigationStack {
            TaskDetailView(model)
        }
.preferredColorScheme(scheme)
.frame(width: detailWidth, height: height), width: detailWidth, height: height, appearance: scheme)
        defer { fixture.close() }
        await waitUntil { fixture.find("Original request") != nil && fixture.find("Task snapshot facts and actions") != nil }
        try fixture.requireRequestedBounds()
        // when — all approved disclosures coexist in the real task-detail layout.
        for label in ["Original request", "assistant_text", "Task snapshot facts and actions", "Reported result, usage and artifacts"] {
            let control = try #require(fixture.find(label))
            #expect(fixture.press(control), Comment(rawValue: "\(label) must remain operable"))
        }
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.find("Copy original request") != nil }
        // then
        #expect(fixture.find("Copy original request") != nil)
        #expect(fixture.find("Public normalized events · bounded record window") != nil)
        #expect(fixture.find("Task snapshot facts and actions") != nil)
        #expect(fixture.find("Reported result, usage and artifacts") != nil)
        for removed in ["Activity", "Summary", "Prompt", "Inspector"] { #expect(fixture.find(removed) == nil) }
        #expect(fixture.host.fittingSize.width <= detailWidth + 1)
        let scrolls = descendantViews(fixture.host).compactMap { $0 as? NSScrollView }
        #expect(scrolls.contains { $0.contentView.bounds.height >= 80 && $0.contentView.bounds.width >= 200 },
                "the expanded request and Events disclosures must leave a usable content viewport")
        #expect(scrolls.contains { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 },
                "expanded Events facts and results must be reachable through the actual scroll hierarchy")
        let copy = try #require(fixture.find("Copy original request"))
        let copyFrame = try #require(fixture.frame(copy))
        #expect(copyFrame.width > 30 && copyFrame.height > 10)
        #expect(copyFrame.minX >= 0 && copyFrame.maxX <= detailWidth)
        let appearance = scheme == .dark ? "dark" : "light"
        try await fixture.captureIfRequested(name: "task-detail-content-\(Int(detailWidth))-within-reference-\(Int(width))-\(appearance)")
    }

    private func seedScrollableObservation(_ model: TaskDetailViewModelMock) throws {
        // The default preview is intentionally short; this bounded record exercises real disclosure scrolling.
        let text = (0 ..< 90).map { "Captured line \($0): preserve bounded normalized evidence and readable task history." }.joined(separator: "\n")
        let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string(WireContract.events.format),
            "v": .number(1), "product_version": .string("0.0.8"), "seq": .number(1), "observed_at": .null,
            "kind": .string("assistant_text"), "text": .string(text)]
        let record = try #require(TaskEventRecord(raw: raw))
        let event = try #require(TaskEvent(line: JSONValue.object(raw).rendered()))
        let items = Timeline.items(from: [event])
        let scope = FeatureObservationFixture.scope
        let frame = EventObservationFrame(taskID: model.taskID, scope: scope,
            records: [.init(id: .init(scope: scope, admission: 0), record: record)], events: [event], items: items,
            history: .init(caughtUp: true), summary: .init(state: .observed, counts: ActivityCounts(), totalFiles: 0))
        model.observationFrames = [model.taskID: frame]
        model.orderedHistoryFrames = [frame]
        let task = try #require(model.task)
        let rows = ConversationTimeline.rows(itemMembers: [.init(task: task, items: items, prompt: nil, identityScope: scope.identity)])
        model.timelineModel = TimelinePaneModel(stepCountText: "1 activity item", rows: rows,
            start: task.startedAt, emptyText: nil, subTaskStrip: nil, isLoading: false)
    }

    private func descendantViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }
}
