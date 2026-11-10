import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStateTreatmentHostedTests

/// Isolated native-feed coverage of the four approved H2a1 treatments.
@MainActor @Suite(.serialized) struct TaskStateTreatmentHostedTests {
    static let titles = ["The process watching this run is gone", "Harflow can't confirm this run",
                         "Reconstructed outcome", "Outcome inferred, not observed"]
    static let messages = [
        "Captured output has stopped and no later summary is promised. The run itself may still be working. "
            + "Check its changes or stop it before starting a replacement.",
        "It can't tell whether the process watching this run is alive. Output may or may not still be captured, "
            + "and a later summary is unknown. Check status again before starting a replacement.",
        "Harflow did not see this process exit. Done comes from the run's own closing output.",
        "Harflow never saw this process exit and found no result in its output, so it reports failed. Nothing it had already written was undone."
    ]
    static let kinds: [TaskStateTreatment.Kind] = [.ownerLost, .unverified, .reconstructed, .unknownFailed]

    final class Actions {
        var stop = 0
        var refresh = 0
        var copy = 0
        var events = 0
    }

    func treatment(_ kind: TaskStateTreatment.Kind, copy: Bool = true) -> TaskStateTreatment {
        TaskStateTreatment(taskID: PaneMocks.taskID, kind: kind, isStopDisabled: false, showsCopyResumeCommand: copy)
    }

    func feed(_ model: TaskStateTreatment?, state: ParallelColumnUIState, actions: Actions) -> some View {
        TimelinePaneView(model: ActivityFeedTranscriptStyleHostedTests.timelineModel(
            (1 ... 24).map { ActivityFixture.text($0, String(repeating: "Captured activity \($0) remains readable. ", count: 6), task: PaneMocks.taskID) }
                + [ActivityFixture.tool(25, task: PaneMocks.taskID, resolved: false)]), state: state, style: .transcript, stateTreatment: model,
                         onStateStop: { actions.stop += 1 }, onStateRefresh: { actions.refresh += 1 },
                         onStateCopyResumeCommand: { actions.copy += 1 }, onStateOpenEvents: { actions.events += 1 })
            .environment(\.hfReduceMotionOverride, true)
    }

    func table(_ host: PaneHost) throws -> ActivityFeedNativeTableView {
        try #require(ActivityFeedTranscriptStyleHostedTests.tables(host.page.host).first)
    }

    func treatmentIndex(_ table: ActivityFeedNativeTableView) -> Int? {
        table.owner?.entries.firstIndex { if case .taskState = $0 { return true }; return false }
    }

    func reveal(_ index: Int, table: ActivityFeedNativeTableView, host: PaneHost) async {
        guard let scroll = table.enclosingScrollView else { return }
        let limit = max(0, table.bounds.maxY - scroll.contentView.bounds.height)
        activityNativeTestScroll(scroll, to: min(max(0, table.rect(ofRow: index).minY), limit))
        await host.pump()
        table.layoutSubtreeIfNeeded()
    }

    @Test(arguments: [false, true], [588, 728, 1000, 1600] as [CGFloat])
    func givenFourTreatments_whenHostedAtApprovedWidths_thenNativeOrderMeasuredHeightAndButtonsRemainReachable(dark: Bool, width: CGFloat) async throws {
        for (offset, kind) in Self.kinds.enumerated() {
            // given
            let state = ParallelColumnUIState()
            let host = PaneHost(feed(treatment(kind), state: state, actions: Actions()), size: CGSize(width: width, height: 620), dark: dark)
            defer { host.close() }
            await host.page.settle { state.viewportPositioned }
            let table = try table(host)
            let owner = try #require(table.owner)
            let index = try #require(treatmentIndex(table))
            let rows = owner.entries.indices.filter { if case .row = owner.entries[$0] { return true }; return false }
            let bottom = try #require(owner.entries.firstIndex { if case .bottom = $0 { return true }; return false })

            // when
            await reveal(index, table: table, host: host)

            // then — actual native rows; 728/588 cover minimum and split detail widths after native sidebar/pane space.
            #expect(table.numberOfRows == owner.entries.count)
            #expect(index < bottom)
            if kind == .reconstructed {
                #expect(rows.allSatisfy { index < $0 })
            } else {
                #expect(rows.allSatisfy { index > $0 })
                for candidate in owner.entries.indices {
                    switch owner.entries[candidate] {
                    case .tail, .approval: #expect(candidate < index)
                    default: break
                    }
                }
            }
            #expect(host.page.element(Self.messages[offset]) != nil)
            let title = try #require(host.page.element(Self.titles[offset]))
            let titleFrame = try #require(host.page.frame(title))
            let scroll = try #require(table.enclosingScrollView)
            let column = scroll.convert(scroll.bounds, to: nil)
            #expect(titleFrame.minX >= column.minX)
            #expect(titleFrame.maxX <= column.maxX)
            let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ActivityFeedNativeCell)
            let root = try #require(cell.host)
            #expect(abs(root.fittingSize.height - table.rect(ofRow: index).height) < 3,
                    "native row clips or reserves stale height: \(root.fittingSize.height) / \(table.rect(ofRow: index).height)")
            let labels: [String] = switch kind {
            case .ownerLost: ["Stop task", "Refresh"]
            case .unverified: ["Refresh", "Stop task"]
            case .reconstructed, .stopping, .settling: []
            case .unknownFailed: ["Continue in a new session", "Copy resume command", "Open Events"]
            }
            for label in labels {
                let button = try #require(host.page.element(label))
                let frame = try #require(host.page.frame(button))
                #expect(frame.height > 0 && column.contains(frame), "\(label) cannot be reached inside the feed at \(width)")
            }
            let frames = labels.compactMap { host.page.element($0).flatMap { host.page.frame($0) } }
            for (left, right) in zip(frames, frames.dropFirst()) {
                #expect(left.minX < right.minX || left.minY > right.minY, "approved action order changed")
            }
            try capture(host, name: "state-\(offset)-\(Int(width))-\(dark ? "dark" : "light")")
        }
    }

    @Test func givenWarningWithApprovalAndLiveTail_whenMounted_thenNativeWarningFollowsBothBeforeSentinel() async throws {
        // given
        let request = CallerApprovalRequest(raw: [
            "request_id": .string("state-approval"), "task_id": .string(PaneMocks.taskID), "tool_name": .string("Bash"),
            "disposition": .string("pending"), "delivery": .string("pending"), "execution_outcome": .string("unknown"),
            "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("fixture-command")])])
        ])
        let card = CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request), pending: true,
                                           expanded: true, canRespond: false, notice: nil, submitting: false)
        let timeline = ActivityFeedTranscriptStyleHostedTests.timelineModel([ActivityFixture.tool(1, resolved: false)])
        let state = ParallelColumnUIState()
        let view = ActivityFeedView(rows: timeline.activityRows, start: nil, history: EventHistoryState(), isLoading: false,
                                    tailValue: ActivityFeedTail(liveStep: timeline.liveStep), style: .transcript, state: state,
                                    onLoadMore: nil,
                                    tailPresentation: .standard(.init(liveStep: .init(text: "Fixture working", indicator: .singleDot), approvals: [card])),
                                    stateTreatment: treatment(.ownerLost))
        let host = PaneHost(view.environment(\.hfReduceMotionOverride, true), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.page.settle { state.viewportPositioned }
        let table = try table(host)
        let entries = try #require(table.owner?.entries)
        let warning = try #require(treatmentIndex(table))
        let approval = try #require(entries.firstIndex { if case .approval = $0 { return true }; return false })
        let tail = try #require(entries.firstIndex { if case .tail = $0 { return true }; return false })
        let bottom = try #require(entries.firstIndex { if case .bottom = $0 { return true }; return false })
        // when
        await reveal(warning, table: table, host: host)
        // then — rect ordering checks the document actually lays out in that same order.
        #expect(approval < warning && tail < warning && warning < bottom)
        #expect(table.rect(ofRow: approval).maxY <= table.rect(ofRow: warning).minY)
        #expect(table.rect(ofRow: tail).maxY <= table.rect(ofRow: warning).minY)
        #expect(table.rect(ofRow: warning).maxY <= table.rect(ofRow: bottom).minY)
        #expect(host.page.element(Self.titles[0]) != nil)
    }

    @Test func givenRetainedWarningRow_whenEqualModelGetsNewCallbacks_thenOnlyLatestOwnerReceivesActions() async throws {
        // given
        let state = ParallelColumnUIState()
        let first = Actions()
        let second = Actions()
        let model = treatment(.ownerLost)
        let input = StateFeedInput(treatment: model, actions: first)
        let host = PaneHost(StateFeedMount(input: input, state: state), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.page.settle { state.viewportPositioned }
        let table = try table(host)
        let index = try #require(treatmentIndex(table))
        await reveal(index, table: table, host: host)
        let owner = try #require(table.owner)
        let identifier = owner.entries[index].id
        // when
        input.actions = second
        await host.pump()
        #expect(host.page.press(try #require(host.page.element("Refresh"))))
        #expect(host.page.press(try #require(host.page.element("Stop task"))))
        // then
        #expect(first.refresh == 0 && first.stop == 0)
        #expect(second.refresh == 1 && second.stop == 1)
        #expect(try self.table(host) === table)
        #expect(table.owner === owner)
        #expect(owner.entries[index].id == identifier)
    }

    @Test(arguments: [false, true])
    func givenInferredFailure_whenActionsPressed_thenCopyIsConditionalAndContinueIsDisabled(hasCommand: Bool) async throws {
        // given
        let actions = Actions()
        let state = ParallelColumnUIState()
        let host = PaneHost(feed(treatment(.unknownFailed, copy: hasCommand), state: state, actions: actions), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.page.settle { state.viewportPositioned }
        let table = try table(host)
        await reveal(try #require(treatmentIndex(table)), table: table, host: host)
        // when
        let button = try #require(host.page.element("Continue in a new session"))
        #expect(try #require(isEnabled(button)) == false)
        _ = host.page.press(button)
        #expect(host.page.press(try #require(host.page.element("Open Events"))))
        if hasCommand { #expect(host.page.press(try #require(host.page.element("Copy resume command")))) }
        // then
        #expect(actions.events == 1)
        #expect(actions.copy == (hasCommand ? 1 : 0))
        #expect(actions.stop == 0 && actions.refresh == 0)
        #expect((host.page.element("Copy resume command") != nil) == hasCommand)
        #expect(host.page.element("Continue needs an observed exit and fully read output, which this run does not have.") != nil)
    }

    @Test func givenRetainedNativeFeed_whenTreatmentChangesThenDisappears_thenEntriesAndInkFollowLatestModel() async throws {
        // given
        let state = ParallelColumnUIState()
        let actions = Actions()
        let input = StateFeedInput(treatment: treatment(.ownerLost), actions: actions)
        let host = PaneHost(StateFeedMount(input: input, state: state), size: CGSize(width: 1000, height: 620))
        defer { host.close() }
        await host.page.settle { state.viewportPositioned }
        let table = try table(host)
        let owner = try #require(table.owner)
        let original = owner.entries.compactMap { entry -> String? in if case .row = entry { return entry.id }; return nil }
        let identifier = owner.entries[try #require(treatmentIndex(table))].id
        // when
        input.treatment = treatment(.unverified)
        await host.page.settle {
            table.owner?.entries.contains {
                if case .taskState(let model, _) = $0 { return model.kind == .unverified }
                return false
            } == true
        }
        await reveal(try #require(treatmentIndex(table)), table: table, host: host)
        #expect(host.page.element(Self.titles[1]) != nil)
        #expect(host.page.element(Self.titles[0]) == nil)
        #expect(try self.table(host) === table)
        #expect(table.owner === owner)
        #expect(owner.entries[try #require(treatmentIndex(table))].id == identifier)
        input.treatment = nil
        await host.page.settle { treatmentIndex(table) == nil }
        // then
        #expect(Self.titles.allSatisfy { host.page.element($0) == nil })
        #expect(try self.table(host) === table)
        #expect(table.owner === owner)
        #expect(owner.entries.compactMap { entry -> String? in if case .row = entry { return entry.id }; return nil } == original)
        #expect(table.numberOfRows == owner.entries.count)
    }

    private func isEnabled(_ object: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return getter(object, selector)
    }

    func capture(_ host: PaneHost, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_STATE_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host.page.host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.page.host.bitmapImageRepForCachingDisplay(in: host.page.host.bounds))
        host.page.host.cacheDisplay(in: host.page.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

// MARK: - StateFeedInput

@Observable @MainActor private final class StateFeedInput {
    var treatment: TaskStateTreatment?
    var actions: TaskStateTreatmentHostedTests.Actions

    init(treatment: TaskStateTreatment?, actions: TaskStateTreatmentHostedTests.Actions) {
        self.treatment = treatment
        self.actions = actions
    }
}

// MARK: - StateFeedMount

private struct StateFeedMount: View {
    let input: StateFeedInput
    let state: ParallelColumnUIState

    var body: some View {
        TaskStateTreatmentHostedTests().feed(input.treatment, state: state, actions: input.actions)
    }
}
