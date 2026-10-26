import AppKit
import Combine
@testable import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - LoadingHandoffHostedTests

@MainActor @Suite(.serialized) struct LoadingHandoffHostedTests {
    @Test func givenResolvedResidentLane_whenEvictedAndReentered_thenNativeFeedUnmountsAndRetainedHandoffDoesNotReplay() async throws {
        // given
        let input = HostedLaneInput()
        let fixture = RedesignHost(HostedLane(input: input).environment(\.hfReduceMotionOverride, false),
                                   size: CGSize(width: 400, height: 500))
        defer { fixture.close() }
        await fixture.settle { input.residencyHandoff.phase == .resolved && input.state.activityHandoff.phase == .resolved
            && fixture.descendants.contains { $0 is ActivityFeedNativeScrollView }
        }
        let firstFeed = try #require(fixture.descendants.first { $0 is ActivityFeedNativeScrollView })
        #expect(input.residencyHandoff.hasRevealed && input.state.activityHandoff.hasRevealed)

        // when — eviction must remove the native feed, rather than leave an outgoing copy alive.
        input.resident = false
        await fixture.settle { !fixture.descendants.contains { $0 is ActivityFeedNativeScrollView } }
        #expect(!fixture.descendants.contains { $0 === firstFeed })
        #expect(input.residencyHandoff.phase == .resolved)
        #expect(input.state.activityHandoff.phase == .resolved)
        input.resident = true
        await fixture.settle { fixture.descendants.contains { $0 is ActivityFeedNativeScrollView } }

        // then — a fresh native surface uses the retained selection's already-resolved reveal.
        let secondFeed = try #require(fixture.descendants.first { $0 is ActivityFeedNativeScrollView })
        #expect(secondFeed !== firstFeed)
        #expect(input.residencyHandoff.phase == .resolved)
        #expect(input.state.activityHandoff.phase == .resolved)
        #expect(input.state.expandedGroups == ["retained-disclosure"])
    }

    @Test func givenNonresidentLane_whenFirstResidentThenReentered_thenInitialHandoffPreparesOnlyOnce() async {
        // given — hold the presentation frame so the prepared phase is deterministic.
        let gate = HandoffFrameGate()
        let handoff = SkeletonContentState(waitForPresentedFrame: { await gate.wait() })
        let input = HostedLaneInput(residencyHandoff: handoff)
        input.resident = false
        let fixture = RedesignHost(HostedLane(input: input).environment(\.hfReduceMotionOverride, false),
                                   size: CGSize(width: 400, height: 500))
        defer { gate.release(); fixture.close() }
        await fixture.settle { handoff.hasObservedLoading }
        #expect(handoff.hasObservedLoading)
        #expect(input.activityStateRequests == 0, "A placeholder must not create activity inventory or retained membership")
        #expect(!fixture.descendants.contains { $0 is ActivityFeedNativeScrollView })

        // when — the same rendered descriptor becomes resident for the first time.
        input.resident = true
        await fixture.settle { gate.isWaiting && handoff.phase == .prepared }
        #expect(handoff.phase == .prepared)
        #expect(!handoff.hasRevealed)
        gate.release()
        await fixture.settle { handoff.phase == .resolved && fixture.descendants.contains { $0 is ActivityFeedNativeScrollView } }

        // then — eviction does not reset the retained reveal, and reentry does not wait again.
        input.resident = false
        await fixture.settle { !fixture.descendants.contains { $0 is ActivityFeedNativeScrollView } }
        input.resident = true
        await fixture.settle { fixture.descendants.contains { $0 is ActivityFeedNativeScrollView } }
        #expect(handoff.phase == .resolved)
        #expect(gate.waitCount == 1)
    }

    @Test func givenLoadingSummary_whenHistoryFailsThenResolvesEmpty_thenErrorIsAccessibleAndEmptyHasNoSectionFootprint() async throws {
        // given
        let input = HostedSummaryInput()
        let fixture = RedesignHost(HostedSummary(input: input).environment(\.hfReduceMotionOverride, true),
                                   size: CGSize(width: 500, height: 180))
        let empty = HostedSummaryInput()
        empty.availability = .available
        let baseline = RedesignHost(HostedSummary(input: empty).environment(\.hfReduceMotionOverride, true),
                                    size: CGSize(width: 500, height: 180))
        defer { fixture.close(); baseline.close() }
        await baseline.settle { baseline.element("No answer yet.") != nil }
        await fixture.settle { fixture.descendants.contains { $0 is NSScrollView } }

        // when
        input.availability = .unavailable
        await fixture.settle { fixture.element("Edit history isn't available for this task.") != nil }
        #expect(fixture.element("Files edited") != nil)
        input.availability = .available
        await fixture.settle {
            fixture.element("Files edited") == nil && fixture.element("No answer yet.") != nil
                && abs(documentHeight(fixture) - documentHeight(baseline)) < 1
        }

        // then — no invented empty label and no retained skeleton-sized document space.
        #expect(documentHeight(baseline) > 0)
        #expect(fixture.element("Files edited") == nil)
        #expect(fixture.element("Edit history isn't available for this task.") == nil)
        #expect(abs(documentHeight(fixture) - documentHeight(baseline)) < 1)
    }

    @Test func givenLoadingWorkflow_whenInitialReadFails_thenErrorReplacesSkeletonWithinTheSameViewport() async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        vm.initialLoadingKind = "run"
        let fixture = RedesignHost(WorkflowView(vm).environment(\.hfReduceMotionOverride, true),
                                   size: CGSize(width: 1000, height: 700))
        defer { fixture.close(); vm.didDisappear() }
        await fixture.settle { fixture.host.bounds.size == CGSize(width: 1000, height: 700) }
        let viewport = fixture.host.bounds

        // when
        vm.initialLoadFailed = true
        vm.initialLoadingKind = nil
        await fixture.settle { fixture.element("Workflow could not be loaded") != nil }

        // then
        #expect(fixture.element("Workflow could not be loaded") != nil)
        #expect(fixture.host.bounds == viewport)
        #expect(!fixture.descendants.contains { $0 is ActivityFeedNativeScrollView })
    }

    @Test(arguments: ["Graph", "Parallel"])
    func givenLoadingRun_whenResolved_thenRunModeKeepsItsNativeSplitAndDivider(mode: String) async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        let suite = "LoadingHandoffHostedTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(mode, forKey: "workflowViewMode")
        vm.initialLoadingKind = "run"
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(defaults).environment(\.hfReduceMotionOverride, true),
                                   size: CGSize(width: 1000, height: 700))
        defer { fixture.close(); vm.didDisappear(); defaults.removePersistentDomain(forName: suite) }
        await fixture.settle { fixture.descendants.contains { ($0 as? NSSplitView)?.isVertical == true } }
        let split = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first { $0.isVertical })
        #expect(split.arrangedSubviews.count == 2)
        await fixture.settle {
            abs((split.arrangedSubviews.last?.bounds.width ?? 0) - WorkflowRunLayout.defaultInspectorIdeal) < 1
        }
        split.setPosition(640, ofDividerAt: 0)
        fixture.host.layoutSubtreeIfNeeded()
        let positions = split.arrangedSubviews.map(\.frame.minX)
        let widths = split.arrangedSubviews.map(\.frame.width)

        // when — freeze polling before supplying the resolved presentation fixture.
        vm.didDisappear()
        vm.initialLoadFailed = false
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("handoff-run"), "status": .string("running")])
        vm.initialLoadingKind = nil
        await fixture.settle {
            fixture.descendants.contains { $0 === split } && split.arrangedSubviews.map(\.frame.minX) == positions && split.arrangedSubviews.map(\.frame.width) == widths
                && (mode == "Graph" ? fixture.element("Zoom in") != nil : true)
        }

        // then — retain the split and horizontal divider. Header metadata can change natural height.
        #expect(fixture.descendants.contains { $0 === split })
        #expect(split.arrangedSubviews.map(\.frame.minX) == positions && split.arrangedSubviews.map(\.frame.width) == widths)
        if mode == "Parallel" { #expect(fixture.canvasScroll == nil) }
    }

    private func documentHeight(_ fixture: RedesignHost) -> CGFloat {
        fixture.descendants.compactMap { $0 as? NSScrollView }.first?.documentView?.frame.height ?? 0
    }
}

// MARK: - HostedLaneInput

@MainActor @Observable private final class HostedLaneInput {
    var resident = true
    let state = ParallelColumnUIState()
    let residencyHandoff: SkeletonContentState
    let handoffs: ParallelResidencyHandoffStore
    @ObservationIgnored var activityStateRequests = 0
    init(residencyHandoff: SkeletonContentState = SkeletonContentState()) {
        self.residencyHandoff = residencyHandoff
        self.handoffs = ParallelResidencyHandoffStore(states: ["handoff-lane": residencyHandoff])
        state.expandedGroups = ["retained-disclosure"]
    }
}

private struct HostedLane: View {
    let input: HostedLaneInput
    var body: some View {
        let task = TaskInfo(.object(["task_id": .string("handoff-lane"), "backend": .string("claude"),
                                     "status": .string("completed"), "repo_path": .string("/repo")]))!
        let model = ParallelColumnModel(id: task.taskID, task: task, title: "Retained lane", subtitle: "Agent", isBusy: false,
            outcomeMessage: nil, showPrompt: false, prompt: nil, rows: [], activityRows: [], liveStep: nil, isLoading: false,
            summary: nil, onTapTakeover: {}, onTapOpenTask: {}, isResident: input.resident)
        ScrollView(.horizontal) {
            ParallelColumnsContent(columns: [model], availableSize: CGSize(width: 400, height: 500),
                                   stateForColumn: { _ in input.activityStateRequests += 1; return input.state },
                                   onViewport: { _, _ in }, residencyHandoffs: input.handoffs)
        }
    }
}

// MARK: - HostedSummaryInput

@MainActor @Observable private final class HostedSummaryInput {
    var availability = EventAvailability.loading
}

private struct HostedSummary: View {
    let input: HostedSummaryInput
    var body: some View {
        SummaryPaneView(model: SummaryPaneModel(hero: nil, finalAnswer: nil, finalAnswerPlaceholder: "No answer yet.",
            refusalLines: ["Retained warning"], editedFilesAvailability: input.availability, editedFiles: [], editedFilesNote: nil,
            numTurns: nil, inputTokens: nil, outputTokens: nil, costUSD: nil))
    }
}

// MARK: - HandoffFrameGate

@MainActor @Observable private final class HandoffFrameGate {
    private(set) var waitCount = 0
    private(set) var isWaiting = false
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        waitCount += 1
        await withCheckedContinuation {
            continuation = $0
            isWaiting = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}
