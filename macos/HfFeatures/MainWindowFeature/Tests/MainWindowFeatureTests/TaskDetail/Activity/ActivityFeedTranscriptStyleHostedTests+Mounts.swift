import AppKit
import Combine
import HfCommon
import HfCommonTestMock
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
@testable import MonitorCore
import SwiftUI
import Testing

// MARK: - ActivityFeedTranscriptStyleHostedTests + mounts

/// Which surfaces mount which `ActivityFeedStyle`, the Group promotion from detail to Parallel, and the optional
/// review captures (`HARFLOW_M04_CAPTURE_DIR`). An extension, so the tests belong to the same serialized suite.
extension ActivityFeedTranscriptStyleHostedTests {

    // MARK: Mount guards

    @Test func givenCoordinatorBuiltTaskDetail_whenInspected_thenItCarriesTheTranscriptStyle() throws {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        // when
        let view = sut.buildTaskDetailView(id: "abc123")
        // then
        #expect(Self.transcriptStyle(in: view) == .transcript)
    }

    @Test func givenTaskDetailView_whenBuiltWithoutAStyleOrEmbedded_thenItStaysStandard() async throws {
        // given / when
        let plain = TaskDetailView(TaskDetailViewModelMock())
        let embedded = TaskDetailView(TaskDetailViewModelMock(), chrome: .embedded)
        let styled = TaskDetailView(TaskDetailViewModelMock(), transcriptStyle: .transcript)
        // then
        #expect(Self.transcriptStyle(in: plain) == .standard)
        #expect(Self.transcriptStyle(in: embedded) == .standard)
        #expect(Self.transcriptStyle(in: styled) == .transcript)
    }

    @Test(arguments: [false, true])
    func givenMountedTaskDetail_whenStyled_thenTheFeedTableHostsThatStyle(embedded: Bool) async throws {
        // given
        _ = NSApplication.shared
        for style in [ActivityFeedStyle.standard, .transcript] {
            let mock = TaskDetailViewModelMock()
            mock.timelineModel = Self.timelineModel(Self.syntheticRows(done: true))
            let host = NSHostingView(rootView: AnyView(
                TaskDetailView(mock, chrome: embedded ? .embedded : .group, transcriptStyle: style)
                    .environment(\.hfReduceMotionOverride, true)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            // when
            await waitUntil(timeout: 8) { Self.tables(host).first?.owner?.model != nil }
            // then
            let table = try #require(Self.tables(host).first)
            #expect(table.owner?.model?.style == style, "embedded=\(embedded)")
        }
    }

    @Test func givenMountedGroupDetail_whenPromotedToParallel_thenDetailIsTranscriptAndParallelLanesAreLane() async throws {
        // given
        let first = Self.task("first", status: "completed", session: "shared")
        let second = Self.task("second", status: "running", session: "new")
        let detailHarness = TaskDetailVMTests().makeSUT(taskID: "first")
        detailHarness.detailBox.value = first
        let events = Self.retainedEvents()
        detailHarness.eventsBox.value = events
        detailHarness.itemsOverride.value = Timeline.items(from: events)
        let parallelHarness = ParallelVMTests().makeSUT(groupName: "group")
        parallelHarness.eventsBox.value["first"] = events
        parallelHarness.itemsBox.value["first"] = Timeline.items(from: events)
        parallelHarness.availabilityBox.value["first"] = .available
        let tasks = CurrentValueSubject<[TaskInfo], Never>([first])
        let useCase = MockGroupPresentationUseCase()
        given(useCase).tasksPublisher().willReturn(tasks.eraseToAnyPublisher())
        let sut = GroupPresentationVM(groupName: "group", useCase: useCase,
                                      makeDetail: { _ in detailHarness.sut },
                                      makeParallel: { parallelHarness.sut })
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GroupPresentationView(sut).frame(width: 900, height: 600))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            sut.didDisappear()
            detailHarness.sut.didDisappear()
            parallelHarness.sut.didDisappear()
        }
        await waitUntil(timeout: 5) { sut.detailVM === detailHarness.sut }
        try #require(sut.detailVM === detailHarness.sut)
        detailHarness.sut.didAppear()
        await waitUntil(timeout: 8) { Self.tables(host).first?.owner?.model != nil }

        // then — the standalone mount uses the transcript.
        let detailTable = try #require(Self.tables(host).first)
        #expect(detailTable.owner?.model?.style == .transcript)

        // given — a paused reader in the transcript detail: scrolled mid-feed, anchor captured, live-follow off.
        let (pausedAnchor, offsetBefore) = try await pauseReader(in: detailTable, state: sut.activityState)
        let retainedState = sut.activityState

        // when — a second member promotes the group to Parallel.
        parallelHarness.tasksBox.value["first"] = first
        parallelHarness.tasksBox.value["second"] = second
        parallelHarness.tasksSubject.send([first, second])
        tasks.send([first, second])
        await waitUntil(timeout: 8) { sut.parallelVM === parallelHarness.sut }
        try #require(sut.parallelVM === parallelHarness.sut)
        await waitUntil(timeout: 8) { Self.tables(host).first?.owner?.model != nil }

        // then — Parallel lanes use the lane style (the transcript metrics at lane insets).
        let parallelTables = Self.tables(host)
        try #require(!parallelTables.isEmpty, "no Parallel feed table mounted")
        for table in parallelTables { #expect(table.owner?.model?.style == .lane) }

        // then — where the paused anchor sits in the Parallel column's own feed once it has positioned.
        await waitUntil(timeout: 8) { retainedState.viewportPositioned }
        let parallelTable = try #require(Self.tables(host).first)
        let offsetAfter = Self.viewportOffset(of: pausedAnchor.id, in: parallelTable)
        let after = try #require(offsetAfter, "the Parallel feed does not hold the anchor row")
        #expect(abs(after - offsetBefore) < 3, "anchor viewport offset \(offsetBefore) before promotion, \(after) after")

        // then — what is established across the promotion: Parallel mounts a different feed with a fresh coordinator,
        // so the anchor is not re-resolved here; the reading state it would resume from is what survives. The group
        // hands the very same `ParallelColumnUIState` to the Parallel VM, still paused on the same anchor.
        #expect(sut.hasPromotedActivity)
        #expect(sut.activityState === retainedState)
        #expect(parallelHarness.sut.uiStates.values.contains { $0 === retainedState }, "Parallel did not adopt the retained state")
        #expect(retainedState.anchor == pausedAnchor, "the paused anchor changed across promotion")
        #expect(!retainedState.followLive.isFollowing, "live-follow resumed across promotion")
    }

    // MARK: Captures

    @Test(arguments: ["task-running", "task-done"], [false, true])
    func givenSyntheticTranscript_whenCaptureDirectorySet_thenStyledTaskDetailIsCapturedAtBothSizes(state: String, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let done = state == "task-done"
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)] {
            // given — the styled TaskDetail mount over a preview VM; no engine or user state.
            _ = NSApplication.shared
            let mock = done ? TaskDetailViewModelMock.finished() : TaskDetailViewModelMock()
            let rows = Self.syntheticRows(done: done)
            mock.timelineModel = Self.timelineModel(rows)
            let uiState = ParallelColumnUIState()
            let group = try #require(mock.timelineModel.activityRows.compactMap(\.group).first)
            uiState.expandedGroups = [group.id]
            uiState.disclosures.expandedTools = [Self.taskID + ":c-edit-expanded"]
            let root = NavigationStack { TaskDetailView(mock, activityState: uiState, transcriptStyle: .transcript) }
                .preferredColorScheme(dark ? .dark : .light)
                .environment(\.hfReduceMotionOverride, true)
            let controller = NSHostingController(rootView: root)
            controller.sceneBridgingOptions = .all
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderFront(nil)
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            defer { window.contentViewController = nil; window.close() }
            let host = controller.view

            // when
            await waitUntil(timeout: 8) {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                return NSApp.isActive && window.isKeyWindow && Self.tables(host).first?.owner?.model?.style == .transcript
            }
            await DisplayFrames.waitForPresentedFrame()

            // then
            let table = try #require(Self.tables(host).first)
            #expect(table.owner?.model?.style == .transcript)
            let name = "m05-\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-host-bitmap.png"))
            try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
            let geometry = ["content": NSStringFromRect(host.bounds), "outerWindow": NSStringFromRect(window.frame),
                            "mount": "TaskDetailView(transcriptStyle: .transcript) over TaskDetailViewModelMock",
                            "designReference": "HarflowDesign 24958cf v2/scripts/screens-task.js " + state.replacingOccurrences(of: "-", with: "/"),
                            "reduceMotion": "true"]
            try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appendingPathComponent(name + ".json"))
        }
    }

    // MARK: Helpers

    /// Scrolls the detail feed mid-way until the reader is paused with a captured anchor; returns the anchor and the
    /// anchor row's actual offset from the top of the viewport.
    private func pauseReader(in table: ActivityFeedNativeTableView, state: ParallelColumnUIState) async throws
        -> (ParallelVerticalAnchor, CGFloat) {
        let owner = try #require(table.owner)
        await waitUntil(timeout: 8) { state.viewportPositioned && owner.entries.count > 20 }
        let target = owner.entries.firstIndex { $0.id.hasSuffix("#20") } ?? owner.entries.count / 2
        activityNativeTestScroll(try #require(table.enclosingScrollView), to: table.rect(ofRow: target).minY + 30)
        await waitUntil(timeout: 5) { !state.followLive.isFollowing && state.anchor != nil }
        try #require(!state.followLive.isFollowing, "the reader never paused")
        let anchor = try #require(state.anchor)
        let offset = try #require(Self.viewportOffset(of: anchor.id, in: table), "anchor row is not in the detail feed")
        return (anchor, offset)
    }

    /// The row's top edge relative to the top of the visible viewport, when the feed holds the row.
    private static func viewportOffset(of id: String, in table: ActivityFeedNativeTableView) -> CGFloat? {
        guard let owner = table.owner, let row = owner.entries.firstIndex(where: { $0.id == id }),
              let scroll = table.enclosingScrollView else { return nil }
        return table.rect(ofRow: row).minY - scroll.documentVisibleRect.minY
    }

    /// Sixty long paragraphs, so the feed scrolls and a reader can pause mid-feed.
    private static func retainedEvents() -> [TaskEvent] {
        (0 ..< 60).map { seq in
            TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
                + #""seq":\#(seq),"kind":"assistant_text","text":"Retained history paragraph \#(seq). "#
                + String(repeating: "It wraps across the reading width. ", count: 6) + #""}"#)!
        }
    }

    /// The `transcriptStyle` stored by the `TaskDetailView` inside a (possibly type-erased) view,
    /// read by reflection from the value the builder produced.
    private static func transcriptStyle(in value: Any, depth: Int = 0) -> ActivityFeedStyle? {
        guard depth < 14 else { return nil }
        for child in Mirror(reflecting: value).children {
            if child.label == "transcriptStyle", let style = child.value as? ActivityFeedStyle { return style }
            if let style = transcriptStyle(in: child.value, depth: depth + 1) { return style }
        }
        return nil
    }

    private static func task(_ id: String, status: String, session: String) -> TaskInfo {
        TaskInfo(.object([
            "task_id": .string(id), "group": .string("group"), "session_id": .string(session),
            "backend": .string("codex"), "repo_path": .string("/repo"), "status": .string(status),
            "started_at": .string("2026-01-01T00:00:00Z")
        ]))!
    }

    /// `task/running` and `task/done` shaped content: prose with inline code, a fenced code block and a list; an
    /// expanded read group (file pills) and a collapsed one; collapsed and expanded single tool rows; a turn
    /// separator with a follow-up; a notice; (done) the finished marker; (running) a live step for the working row.
    private static func syntheticRows(done: Bool) -> [ConversationTimelineRow] {
        func call(_ id: String, category: String, tool: String, path: String? = nil, old: String? = nil,
                  new: String? = nil, input: String) -> TaskEvent.ToolCall {
            TaskEvent.ToolCall(callID: id, tool: tool, category: category, inputPreview: input, path: path,
                               command: nil, editOld: old, editNew: new)
        }
        func result(_ id: String, _ output: String) -> TaskEvent.ToolResult {
            TaskEvent.ToolResult(callID: id, ok: true, outputTail: output, exitCode: nil)
        }
        let task = taskID
        let intro = "I'll start with the slot release path and the test, "
            + "then look for a race between the release call and the waiter being woken."
        let cause = "Found a likely cause. `SlotPool.release()` sets the slot free and then notifies waiters outside the lock."
            + "\n\nThe fix is to update the count and notify under the same lock:\n\n"
            + "```python\nwith self._lock:\n    self._free += 1\n    self._cond.notify_all()\n```\n\n"
            + "- move `notify_all()` inside the `with self._lock` block\n- re-check the free count in the waiter loop"
        let closing = done ? "The retry path already re-checks the count, so no change was needed there."
            : "Checking the retry path next."
        func tool(_ seq: Int, _ id: String, _ kind: (category: String, name: String), _ path: String, _ output: String)
            -> ConversationTimelineRow {
            ActivityFixture.row(seq, task: task, live: !done,
                                .tool(call(id, category: kind.category, tool: kind.name, path: path, input: path), result(id, output)))
        }
        var rows: [ConversationTimelineRow] = [
            ActivityFixture.text(1, intro, task: task),
            tool(2, "c-read-1", ("read", "Read"), "/repo/slots.py", ""),
            tool(3, "c-read-2", ("read", "Read"), "/repo/test_slots.py", ""),
            ActivityFixture.text(4, cause, task: task),
            tool(5, "c-edit-collapsed", ("edit", "Edit"), "/repo/slots.py", "ok"),
            tool(6, "c-edit-expanded", ("write", "Write"), "/repo/notes.txt", "Wrote 12 lines\nFormatted with ruff"),
            ActivityFixture.separator("Also check the retry path.", task: task),
            // A second read group, left collapsed in the captures.
            ActivityFixture.row(11, task: task, live: false,
                .tool(call("c-read-3", category: "read", tool: "Read", path: "/repo/retry.py", input: "/repo/retry.py"), result("c-read-3", ""))),
            ActivityFixture.row(12, task: task, live: false,
                .tool(call("c-read-4", category: "read", tool: "Read", path: "/repo/pool.py", input: "/repo/pool.py"), result("c-read-4", ""))),
            ActivityFixture.text(7, closing, task: task),
            ActivityFixture.row(13, task: task, live: false, .notice("Two older runs were removed by retention."))
        ]
        if done {
            rows.append(ActivityFixture.row(14, task: task, live: false, .finished(status: "completed", exitCode: 0, summary: nil)))
        }
        if !done {
            rows.append(ActivityFixture.row(8, task: task, live: true,
                .tool(call("c-run", category: "shell", tool: "Bash", input: "pytest tests/test_slots.py -k release"), nil)))
        }
        return rows
    }
}
