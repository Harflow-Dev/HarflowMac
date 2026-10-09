import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    /// Explicit opt-in; timings describe model settlement, never displayed pixels or frame times.
    @Test func benchmarkParallelResidency() async throws {
        guard let output = ProcessInfo.processInfo.environment["PB_PARALLEL_BENCHMARK_OUTPUT"] else { return }
        var records: [[String: Any]] = []
        for count in [8, 64, 256] {
            for turns in [1, 16] {
                for callCount in [2, 256] {
                    let fixture = try benchmarkFixture(count: count, turns: turns, calls: callCount)
                    for sample in 0 ..< 10 {
                        let sampleRecords = try await benchmarkSample(count: count, turns: turns, calls: callCount,
                            sample: sample, fixture: fixture)
                        records.append(contentsOf: sampleRecords)
                    }
                }
            }
        }
        let document: [String: Any] = ["measurement_boundary": "internal model settlement or eager CPU; no displayed latency",
                                     "observations": records]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }

    private func benchmarkSample(count: Int, turns: Int, calls callCount: Int, sample: Int,
                                 fixture: (tasks: [TaskInfo], conversations: [Conversation], items: [TimelineItem])) async throws -> [[String: Any]] {
        let harness = makeSUT()
        let recorder = ParallelBenchmarkRecorder(count: count, turns: turns, calls: callCount, sample: sample, sut: harness.sut)
        harness.sut.updateViewport(offset: 0, width: 842)
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: fixture.tasks.map { ($0.taskID, $0) })
        harness.itemsBox.value = Dictionary(uniqueKeysWithValues: fixture.tasks.map { ($0.taskID, fixture.items) })
        harness.availabilityBox.value = Dictionary(uniqueKeysWithValues: fixture.tasks.map { ($0.taskID, .available) })
        let liveID = "c\(count - 1)-t\(turns - 1)"
        let activity = PassthroughSubject<[TimelineItem], Never>()
        harness.itemSubjectsBox.value[liveID] = activity
        var start = DispatchTime.now().uptimeNanoseconds
        // Characterizes the former eager timeline work, excluding subscription/I/O/UI costs.
        for conversation in fixture.conversations {
            let input = benchmarkInput(conversation, items: fixture.items)
            let value = benchmarkEagerPresentation(input)
            recorder.eagerRows += value.rows.count + value.activityRows.count
        }
        recorder.record("eager_timeline_cpu", start, eager: true)
        start = DispatchTime.now().uptimeNanoseconds
        harness.sut.didAppear()
        harness.tasksSubject.send(fixture.tasks)
        await waitUntil(timeout: 30) { harness.sut.columns.count == count && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.count == count && harness.sut.isPresentationSettled)
        recorder.record("initial_model_settlement", start)
        start = DispatchTime.now().uptimeNanoseconds
        harness.sut.updateViewport(offset: 421 * 4, width: 842)
        await waitUntil(timeout: 30) { harness.sut.isPresentationSettled }
        recorder.record("viewport_crossing", start)
        start = DispatchTime.now().uptimeNanoseconds
        for index in [0, 4, 1, 5, 0] { harness.sut.updateViewport(offset: CGFloat(index) * 421, width: 842) }
        await waitUntil(timeout: 30) { harness.sut.isPresentationSettled }
        recorder.record("rapid_reversal", start)
        let event = try #require(TaskEvent(line: "{\"v\":1,\"seq\":99999,\"kind\":\"assistant_text\",\"text\":\"synthetic delta\"}"))
        let extra = Timeline.items(from: [event])
        let oldBuilds = harness.sut.builtColumnCount
        start = DispatchTime.now().uptimeNanoseconds
        activity.send(fixture.items + extra)
        await waitUntil(timeout: 30) { harness.sut.builtColumnCount > oldBuilds && harness.sut.isPresentationSettled }
        recorder.record("resident_activity_update", start)
        start = DispatchTime.now().uptimeNanoseconds
        harness.sut.didTapViewPrompt()
        await waitUntil(timeout: 30) { harness.sut.isPresentationSettled }
        recorder.record("prompt_toggle", start)
        let oldUpdates = harness.sut.sourceUpdateCount
        let oldWrites = harness.sut.presentationWriteCount
        let oldBuildCount = harness.sut.builtColumnCount
        start = DispatchTime.now().uptimeNanoseconds
        harness.tasksSubject.send(fixture.tasks)
        await waitUntil(timeout: 30) { harness.sut.sourceUpdateCount > oldUpdates && harness.sut.isPresentationSettled }
        recorder.record("unchanged_poll", start)
        #expect(harness.sut.presentationWriteCount == oldWrites)
        #expect(harness.sut.builtColumnCount == oldBuildCount)
        #expect(harness.sut.leasedMemberCount <= 4 * turns)
        harness.sut.didDisappear()
        return recorder.records
    }

    /// Canonical former presentation pipeline; no new worker cancellation checkpoints.
    private func benchmarkEagerPresentation(_ input: ParallelColumnInput) -> ParallelColumnPresentation {
        let members = input.members.map { ConversationItemMember(task: $0.task, items: $0.items, prompt: $0.prompt) }
        let raw = ConversationTimeline.rows(itemMembers: members)
        let tasks = Dictionary(uniqueKeysWithValues: members.map { ($0.task.taskID, $0.task) })
        let rows = WorkflowNodePresentation.visibleRows(raw, tasks: tasks, compact: true)
        var result = input.base
        result.rows = rows
        result.activityRows = ActivityRowsBuilder.build(from: rows)
        result.liveStep = LiveStep(rows: rows, isRunning: result.task.status.isRunning)
        result.pendingMessages = PendingMessage.visible(snapshot: input.snapshot, events: input.events)
        result.isLoading = input.members.allSatisfy(\.items.isEmpty) && input.members.contains { $0.availability == .loading }
        return result
    }

    private func benchmarkFixture(count: Int, turns: Int, calls: Int) throws
        -> (tasks: [TaskInfo], conversations: [Conversation], items: [TimelineItem]) {
        var events: [TaskEvent] = []
        var seq = 0
        func append(_ value: [String: JSONValue]) throws {
            var payload = value
            seq += 1
            payload["v"] = .number(1)
            payload["seq"] = .number(Double(seq))
            events.append(try #require(TaskEvent(line: JSONValue.object(payload).rendered())))
        }
        try append(["kind": .string("task_started"), "prompt": .string("Synthetic fixture")])
        try append(["kind": .string("user_message"), "text": .string("Synthetic fixture"), "source": .string("initial")])
        for index in 0 ..< calls {
            let id = "call-\(index)"
            try append(["kind": .string("tool_call"), "call_id": .string(id), "tool": .string("Read"),
                        "category": .string("read"), "path": .string("/tmp/synthetic/file-\(index).swift"),
                        "input_preview": .string("{}")])
            try append(["kind": .string("tool_result"), "call_id": .string(id), "ok": .bool(true),
                        "output_preview": .string("synthetic output")])
        }
        try append(["kind": .string("assistant_text"), "text": .string("Synthetic answer")])
        try append(["kind": .string("task_finished"), "status": .string("completed")])
        var tasks: [TaskInfo] = []
        var conversations: [Conversation] = []
        for column in 0 ..< count {
            var members: [TaskInfo] = []
            for turn in 0 ..< turns {
                let member = task(id: "c\(column)-t\(turn)", status: turn == turns - 1 ? "running" : "completed",
                    startedAt: Date(timeIntervalSince1970: Double(column * 100 + turn)),
                    parentTaskID: turn == 0 ? nil : "c\(column)-t\(turn - 1)")
                members.append(member)
                tasks.append(member)
            }
            conversations.append(Conversation(members: members))
        }
        return (tasks, conversations, Timeline.items(from: events))
    }

    private func benchmarkInput(_ conversation: Conversation, items: [TimelineItem]) -> ParallelColumnInput {
        let current = conversation.current
        let base = ParallelColumnPresentation(id: conversation.id, task: current, title: "Synthetic fixture",
            subtitle: ParallelColumnModel.subtitle(repoPath: current.repoPath, backend: current.backend, turns: conversation.members.count),
            isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: "Synthetic fixture", summary: nil,
            start: conversation.first.startedAt, memberTaskIDs: Set(conversation.members.map(\.taskID)))
        return ParallelColumnInput(base: base, members: conversation.members.map {
            ParallelMemberInput(task: $0, items: items, prompt: "Synthetic fixture", availability: .available)
        }, events: [], snapshot: nil)
    }
}

@MainActor
private final class ParallelBenchmarkRecorder {
    private let labels: [String: Any]
    private let sut: ParallelVM
    private(set) var records: [[String: Any]] = []
    var eagerRows = 0

    init(count: Int, turns: Int, calls: Int, sample: Int, sut: ParallelVM) {
        self.labels = ["version": 1, "conversations": count, "turns": turns, "tool_calls_per_turn": calls, "sample": sample]
        self.sut = sut
    }

    func record(_ scenario: String, _ start: UInt64, eager: Bool = false) {
        var value = labels
        value["scenario"] = scenario
        let end = DispatchTime.now().uptimeNanoseconds
        value["start_ns"] = start
        value["end_ns"] = end
        value["duration_ms"] = Double(end - start) / 1_000_000
        value["resident_columns"] = sut.residentColumnCount
        value["leased_members"] = sut.leasedMemberCount
        value["presentation_writes"] = sut.presentationWriteCount
        value["built_columns"] = sut.builtColumnCount
        value["eager_cpu_only"] = eager
        if eager { value["eager_processed_rows"] = eagerRows }
        records.append(value)
    }
}
