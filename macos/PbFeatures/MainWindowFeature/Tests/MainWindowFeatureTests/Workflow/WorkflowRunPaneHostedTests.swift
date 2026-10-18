import AppKit
@testable import MainWindowFeature
import Observation
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowRunPaneHostedTests

@MainActor @Suite(.serialized) struct WorkflowRunPaneHostedTests {
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
        await fixture.settle { abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 288) < 1 }
        #expect(abs((split.arrangedSubviews.last?.bounds.width ?? 0) - 288) < 1,
                "The native run plan must actually start at its 288-point ideal")
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
