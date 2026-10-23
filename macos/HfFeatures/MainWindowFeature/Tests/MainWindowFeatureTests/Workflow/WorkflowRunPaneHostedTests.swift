import AppKit
import HfUI
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

// MARK: - WorkflowRunPaneHostedTests

@MainActor @Suite(.serialized) struct WorkflowRunPaneHostedTests {
    @Test func givenLongSummary_whenExpanded_thenCanvasAnchorRemainsStableAndOverlayIsBounded() async throws {
        let vm = WorkflowPreview.make(run: true)
        defer { vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 900, height: 700))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Expand summary") != nil && fixture.canvasScroll != nil }
        let canvas = try #require(fixture.canvasScroll)
        let canvasBaseline = canvas.convert(canvas.bounds, to: fixture.host)
        var raw = vm.selectedRun?.raw ?? [:]
        raw["attention_reason"] = .string(String(repeating: "A long recovery explanation. ", count: 120))
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        await fixture.settle { fixture.element("Expand summary") != nil }
        let expand = try #require(fixture.element("Expand summary"))
        #expect(accessibleCount("Expand summary", in: fixture) == 1)
        let scrollIDsBeforeExpansion = Set(fixture.descendants.compactMap { $0 as? NSScrollView }.map(ObjectIdentifier.init))
        // The summary identifier is attached to a SwiftUI container whose AX
        // exposure varies across macOS releases. The stable public control is
        // the expansion button; its vertical position is the collapsed-strip
        // anchor we need to preserve.
        let before = try #require(fixture.frame(expand))
        #expect(fixture.press(expand))
        await fixture.settle { fixture.element("Collapse summary") != nil }
        #expect(accessibleCount("Collapse summary", in: fixture) == 1)
        let collapse = try #require(fixture.element("Collapse summary"))
        let collapseFrame = try #require(fixture.frame(collapse))
        let expandedScroll = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first {
            guard !scrollIDsBeforeExpansion.contains(ObjectIdentifier($0)), let frame = fixture.frame($0) else {
                return false
            }
            return frame.intersects(collapseFrame) || frame.minY < collapseFrame.minY
        })
        let expandedScrollFrame = try #require(fixture.frame(expandedScroll))
        let expandedBounds = expandedScrollFrame.union(collapseFrame)
        #expect(expandedBounds.height <= 420)
        #expect(collapseFrame.minY > before.minY)
        let canvasExpanded = canvas.convert(canvas.bounds, to: fixture.host)
        #expect(abs(canvasExpanded.minY - canvasBaseline.minY) < 1)
        #expect(abs(canvasExpanded.height - canvasBaseline.height) < 1)
        #expect(fixture.press(collapse))
        await fixture.settle { fixture.element("Expand summary") != nil }
        let canvasCollapsed = canvas.convert(canvas.bounds, to: fixture.host)
        #expect(abs(canvasCollapsed.minY - canvasBaseline.minY) < 1)
        #expect(abs(canvasCollapsed.height - canvasBaseline.height) < 1)
        #expect(accessibleCount("Expand summary", in: fixture) == 1)
        let collapsedExpand = try #require(fixture.element("Expand summary"))
        #expect(abs((fixture.frame(collapsedExpand)?.minY ?? -1) - before.minY) < 1)
    }

    private func accessibleCount(_ label: String, in fixture: RedesignHost) -> Int {
        var seen = Set<ObjectIdentifier>()
        return fixture.elements(in: fixture.host)
.filter {
            seen.insert(ObjectIdentifier($0)).inserted && fixture.matches($0, label)
        }
.count
    }

    @Test(arguments: [900.0, 1200.0], [ColorScheme.light, .dark])
    func givenFreshRunPanes_whenLoadingChanges_thenIdealWidthAppliesOnceAndUserResizePersists(width: Double, appearance: ColorScheme) async throws {
        // given
        let state = HostedRunPaneState()
        let fixture = RedesignHost(HostedRunPaneFixture(state: state).preferredColorScheme(appearance),
                                   size: CGSize(width: width, height: 700))
        defer { fixture.close() }
        await fixture.settle {
            fixture.descendants.compactMap { $0 as? NSSplitView }.first { $0.isVertical }?.arrangedSubviews.count == 2
        }
        let split = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first { $0.isVertical })
        let allSplitsAreVertical = fixture.descendants.compactMap { $0 as? NSSplitView }.allSatisfy(\.isVertical)
        #expect(allSplitsAreVertical,
                "Graph mode keeps activity out of a bottom split")
        await fixture.settle { abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 420) < 1 }
        #expect(abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 420) < 1,
                "The native run plan must actually start at the activity column's 420-point ideal")
        #expect(WorkflowRunLayout.inspectorMinimum == 220)
        #expect(WorkflowRunLayout.inspectorMaximum == 500)
        #expect(WorkflowInspectorWidth.canvasMinimumWidth == 400)

        // when
        split.setPosition(split.bounds.width - 360 - split.dividerThickness, ofDividerAt: 0)
        await fixture.settle { abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 360) < 1 }
        state.loading = true
        await fixture.settle { state.hasLoadingContent && abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 360) < 1 }
        state.loading = false
        await fixture.settle { !state.hasLoadingContent && abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 360) < 1 }

        // then
        #expect(fixture.descendants.contains { $0 === split })
        #expect(abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 360) < 1)
        #expect((split.arrangedSubviews.first?.bounds.width ?? 0) >= 400)
    }
}

// MARK: - HostedRunPaneState

@MainActor @Observable private final class HostedRunPaneState {
    var loading = false
    var hasLoadingContent = false
}

// MARK: - HostedRunPaneFixture

private struct HostedRunPaneFixture: View {
    let state: HostedRunPaneState
    var body: some View {
        WorkflowRunPanes(isGraph: true, isLoading: state.loading) {
            if state.loading { WorkflowLoadingCanvas() } else { Color.inspectorFill }
        } inspector: {
            if state.loading {
                WorkflowLoadingInspector(isRun: true).onAppear { state.hasLoadingContent = true }
            } else {
                Color.cardFill.onAppear { state.hasLoadingContent = false }
            }
        } activity: {
            if state.loading { WorkflowLoadingActivity() } else { Color.cardFill }
        }
    }
}
