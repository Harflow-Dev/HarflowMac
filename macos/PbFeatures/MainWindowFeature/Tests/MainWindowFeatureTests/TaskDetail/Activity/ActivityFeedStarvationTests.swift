import AppKit
@testable import MainWindowFeature
import Mockable
import MonitorCore
import os
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - ActivityFeedStarvationTests

@MainActor @Suite(.serialized) struct ActivityFeedStarvationTests {
    @Test func givenCodeShapedCompletedHistory_whenOpening_thenMainActorKeepsProgressing() async throws {
        try await verifyCompletedHistory(shortFill: false)
    }

    @Test func givenDeliberatelyShortLatestPage_whenAutomaticallyLoadingOlderEvents_thenMainActorKeepsProgressing() async throws {
        try await verifyCompletedHistory(shortFill: true)
    }

    private func verifyCompletedHistory(shortFill: Bool) async throws {
        // given — full code-shaped history, or deliberately shorter text to exercise automatic filling.
        _ = NSApplication.shared
        let pulse = StarvationPulse(path: ProcessInfo.processInfo.environment["PB_ACTIVITY_HEARTBEAT"])
        defer { pulse.finish() }
        try pulse.record(phase: "mounting")
        let delivery = HeartbeatDelivery()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { @Sendable in
            delivery.record()
            Task(priority: .userInitiated) { @MainActor in try pulse.record(phase: "running") }
        }
        timer.resume()
        defer { timer.cancel() }
        let fixture = try ShortHistoryFixture(shortFill: shortFill)
        let defaults = try #require(UserDefaults(suiteName: "ShortActivityStarvation-\(UUID().uuidString)"))
        let controller = NSHostingController(rootView: NavigationStack {
            TaskDetailView(fixture.sut)
        }
.withPresentationContext()
.defaultAppStorage(defaults))
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { fixture.sut.didDisappear(); window.contentViewController = nil; window.close() }
        await waitUntil { @MainActor in pulse.count >= 4 && fixture.sut.timelineModel.isLoading }
        #expect(fixture.sut.timelineModel.isLoading)
        // when — the short variant alone starts at newest 100 and automatically requests older 87.
        let started = Date()
        fixture.publishInitial(shortFill: shortFill)
        let expectedRequests = shortFill ? 1 : 0
        await waitUntil(timeout: 12) { @MainActor in
            Date().timeIntervalSince(started) >= 10 && pulse.count >= 160 && fixture.requests == expectedRequests
                && fixture.sut.rawEvents.count == 187 && !fixture.sut.timelineModel.history.isLoading
        }
        // then — require the expected publication path and sustained actor progress.
        #expect(fixture.requests == expectedRequests)
        #expect(fixture.sut.rawEvents.count == 187)
        #expect(fixture.sut.timelineModel.rows.count == fixture.fullItems.count)
        #expect(!fixture.sut.timelineModel.history.hasMore)
        #expect(!fixture.sut.timelineModel.history.isLoading)
        #expect(pulse.count >= 160, "Timer handler firings: \(delivery.count)")
        try pulse.record(phase: "completed")
    }

    @Test func givenCompletedTaskHierarchy_whenMixedActivityLoads_thenMainActorKeepsProgressing() async throws {
        // given — the actual task VM, deferred detail, navigation, toolbar and timeline hierarchy.
        _ = NSApplication.shared
        let pulse = StarvationPulse(path: ProcessInfo.processInfo.environment["PB_ACTIVITY_HEARTBEAT"])
        defer { pulse.finish() }
        try pulse.record(phase: "mounting")
        let delivery = HeartbeatDelivery()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { @Sendable in
            delivery.record()
            Task(priority: .userInitiated) { @MainActor in try pulse.record(phase: "running") }
        }
        timer.resume()
        defer { timer.cancel() }
        let harness = TaskDetailVMTests().makeSUT()
        harness.detailBox.value = TaskDetailVMTests().task(status: "completed")
        harness.eventsAvailabilityBox.value = .loading
        let defaults = try #require(UserDefaults(suiteName: "ActivityStarvation-\(UUID().uuidString)"))
        let controller = NSHostingController(rootView: NavigationStack {
            TaskDetailView(harness.sut)
        }
.withPresentationContext()
.defaultAppStorage(defaults))
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        await waitUntil(timeout: 3) { @MainActor in pulse.count >= 4 && harness.sut.timelineModel.isLoading }
        #expect(harness.sut.timelineModel.isLoading)
        // when — deliver synthetic items through the same publication boundary as real activity.
        let started = Date()
        let items = mixedItems()
        harness.itemsSubject.send(items)
        harness.eventsAvailabilitySubject.send(.available)
        await waitUntil(timeout: 12) { @MainActor in
            Date().timeIntervalSince(started) >= 10 && pulse.count >= 160
        }
        // then — require actual activity publication as well as independent heartbeat progress.
        #expect(harness.sut.timelineModel.rows.count == items.count)
        #expect(!harness.sut.timelineModel.isLoading)
        #expect(pulse.count >= 160, "Timer handler firings: \(delivery.count)")
        try pulse.record(phase: "completed")
    }

    @Test func givenVariableHeightHistory_whenLoadingIntoNarrowWindow_thenMainActorKeepsProgressing() async throws {
        // given — a watchdog outside this process observes pulses even if the main actor stalls.
        _ = NSApplication.shared
        let pulse = StarvationPulse(path: ProcessInfo.processInfo.environment["PB_ACTIVITY_HEARTBEAT"])
        defer { pulse.finish() }
        try pulse.record(phase: "mounting")
        let delivery = HeartbeatDelivery()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { @Sendable in
            delivery.record()
            Task(priority: .userInitiated) { @MainActor in try pulse.record(phase: "running") }
        }
        timer.resume()
        defer { timer.cancel() }
        let state = ParallelColumnUIState()
        let values = syntheticRows()
        func feed(loaded: Bool) -> some View {
            ActivityFeedView(rows: loaded ? values : [], start: nil, history: EventHistoryState(), isLoading: !loaded,
                             horizontalPadding: 24, state: state, onLoadMore: nil) { Color.clear.frame(height: 1) }
                .readingColumn()
                .frame(maxHeight: .infinity)
        }
        let host = NSHostingView(rootView: feed(loaded: false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 2) { @MainActor in pulse.count >= 2 }
        // when — preserve the feed's identity across the empty/loading to loaded transition.
        let started = Date()
        host.rootView = feed(loaded: true)
        await waitUntil(timeout: 12) { @MainActor in
            Date().timeIntervalSince(started) >= 10 && pulse.count >= 160
        }
        // then — alignment, resize, and reading restoration are separate behaviors.
        #expect(Date().timeIntervalSince(started) >= 10)
        #expect(pulse.count >= 160, "Timer handler firings: \(delivery.count)")
        try pulse.record(phase: "completed")
    }

    private func syntheticRows() -> [ActivityRow] {
        (0 ..< 100).map { index in
            let paragraphs = [1, 3, 20, 1, 80, 2, 6, 40][index % 8]
            let paragraph = "Synthetic activity paragraph \(index) wraps across the reading column to vary row height."
            let text = Array(repeating: paragraph, count: paragraphs).joined(separator: "\n\n")
            return .single(ConversationTimelineRow(id: "variable\(index)", taskID: "synthetic", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(text, seq: index * 10)), live: false))
        }
    }

    private func mixedItems() -> [TimelineItem] {
        var items = [PreviewFixtures.startedItem(prompt: String(repeating: "Synthetic long prompt wraps in the narrow task detail.\n\n", count: 80))]
        for index in 0 ..< 100 {
            let paragraphs = [1, 3, 20, 1, 80, 2, 6, 40][index % 8]
            let text = String(repeating: "Synthetic activity paragraph \(index) varies neighboring row heights.\n\n", count: paragraphs)
            items.append(PreviewFixtures.textItem(text, seq: index * 10 + 1))
            for offset in 0 ..< 3 {
                items.append(PreviewFixtures.toolItem(outputTail: String(repeating: "Synthetic tool output\n", count: 4 + index % 20),
                    seq: index * 10 + offset * 2 + 2, callID: "synthetic-\(index)-\(offset)"))
            }
        }
        items.append(PreviewFixtures.finishedItem(seq: 2000))
        return items
    }
}

// MARK: - ShortHistoryFixture

@MainActor private final class ShortHistoryFixture {
    let sut: TaskDetailVM
    let fullItems: [TimelineItem]
    private let fixtures = TaskDetailVMTests.Fixtures()
    private var history = EventHistoryState(hasMore: true, generation: 1)
    private let fullEvents: [TaskEvent]
    private(set) var requests = 0

    init(shortFill: Bool) throws {
        let events = try Self.events(shortFill: shortFill)
        self.fullEvents = events
        self.fullItems = Timeline.items(from: events)
        let useCase = MockTaskDetailUseCase()
        let routing = MockTaskDetailRouting()
        self.sut = TaskDetailVM(taskID: "abc12345", useCase: useCase, routing: routing)
        useCase.configurePagingDefaults(eventHistory: { [weak self] _ in self?.history ?? EventHistoryState() })
        TaskDetailVMTests().configureStubs(useCase: useCase, routing: routing, taskID: "abc12345", fixtures: fixtures)
        fixtures.detailBox.value = TaskDetailVMTests().task(status: "completed")
        fixtures.eventsAvailabilityBox.value = .loading
        given(useCase).loadMoreEvents(.value("abc12345")).willProduce { [weak self] _ in
            guard let self else { return false }
            requests += 1
            self.history = EventHistoryState(hasMore: true, isLoading: true, generation: 1)
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.history = EventHistoryState(generation: 2)
                fixtures.eventsBox.value = fullEvents
                fixtures.itemsSubject.send(fullItems)
            }
            return true
        }
    }

    func publishInitial(shortFill: Bool) {
        let initial = shortFill ? Array(fullEvents.suffix(100)) : fullEvents
        if !shortFill { history = EventHistoryState(generation: 2) }
        fixtures.eventsBox.value = initial
        fixtures.eventsAvailabilityBox.value = .available
        fixtures.itemsSubject.send(Timeline.items(from: initial))
        fixtures.eventsAvailabilitySubject.send(.available)
    }

    private static func events(shortFill: Bool) throws -> [TaskEvent] {
        let prompt = shapedText(lengths: [63, 124, 438, 103, 92, 0, 121, 89, 136, 69, 0, 55, 71, 35, 90, 74], prompt: true)
        let text = shortFill ? String(String(repeating: "Synthetic short activity text. ", count: 12).prefix(340))
            : shapedText(lengths: [154, 0, 167, 236, 177, 133, 0, 123, 0, 3, 40, 123, 100, 99, 83, 83, 114, 116, 100, 74, 3], prompt: false)
        var fields: [[String: Any]] = [["kind": "task_started", "prompt": prompt, "backend": "claude", "freedom": "read_only"],
                                     ["kind": "user_message", "text": prompt, "source": "initial"]]
        for index in 0 ..< 6 {
            fields.append(["kind": "tool_call", "call_id": "synthetic-\(index)", "tool": "Bash", "category": "shell",
                           "input_preview": "Synthetic local command \(index)", "command": "Synthetic local command \(index)"])
            fields.append(["kind": "tool_result", "call_id": "synthetic-\(index)", "ok": true, "output_tail": "Synthetic output"])
        }
        let characters = Array(text)
        for index in 0 ..< 170 {
            let chunk = String(characters[index * characters.count / 170 ..< (index + 1) * characters.count / 170])
            fields.append(["kind": "assistant_delta", "text": chunk, "message_id": "synthetic-message", "block_index": 0])
        }
        fields.append(["kind": "assistant_text", "text": text, "message_id": "synthetic-message", "block_index": 0])
        fields.append(["kind": "usage", "usage": ["input_tokens": 1, "output_tokens": 1]])
        fields.append(["kind": "task_finished", "status": "completed", "exit_code": 0])
        return try fields.enumerated().map { index, fields in
            var value = fields
            value["v"] = 1
            value["seq"] = index
            let line = try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
            return try #require(TaskEvent(line: line))
        }
    }

    private static func shapedText(lengths: [Int], prompt: Bool) -> String {
        lengths.enumerated()
.map { index, length in
            guard length > 0 else { return "" }
            if !prompt, index == 9 || index == 20 { return "```" }
            if !prompt, index == 11 { return "let " + String(repeating: "s", count: 114) + " = 0;" }
            let pairs = prompt ? (index < 5 ? 2 : 0) : ([0, 2, 3].contains(index) ? 3 : index == 4 ? 2 : 0)
            var prefix = String(repeating: "`sample` ", count: pairs)
            if prompt, index == 2 { prefix += String(repeating: "s", count: 58) + " " }
            let filler = String(repeating: "synthetic text ", count: length)
            return String((prefix + filler).prefix(length))
        }
.joined(separator: "\n")
    }
}

// MARK: - StarvationPulse

@MainActor private final class StarvationPulse {
    private let url: URL?
    private let activity: NSObjectProtocol
    private(set) var count = 0

    init(path: String?) {
        self.url = path.map { URL(fileURLWithPath: $0) }
        // Hosted test windows may be occluded. Measure foreground interaction without App Nap.
        self.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
            reason: "Measure activity feed main-actor responsiveness")
    }

    func finish() { ProcessInfo.processInfo.endActivity(activity) }

    func record(phase: String) throws {
        count += 1
        guard let url else { return }
        let value = "\(ProcessInfo.processInfo.processIdentifier) \(count) \(phase)\n"
        try Data(value.utf8).write(to: url, options: .atomic)
    }
}

/// Distinguish timer delivery from main-actor progress without touching observed UI state.
private final class HeartbeatDelivery: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func record() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
