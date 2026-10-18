import AppKit
@testable import MainWindowFeature
import Observation
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WorkflowRunPanesTests

@MainActor
struct WorkflowRunPanesTests {
    @Test(arguments: [CGSize(width: 1000, height: 700), CGSize(width: 2200, height: 1200)])
    func givenLoadingGraph_whenContentLoads_thenDraggedDividerAndPaneSizesArePreserved(_ size: CGSize) async throws {
        // given
        _ = NSApplication.shared
        let state = PaneState()
        let host = NSHostingView(rootView: PaneFixture(state: state))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let split = try #require(findSplit(in: host, vertical: false))
        split.setPosition(size.height * 0.5, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        let before = split.arrangedSubviews.map(\.frame)
        // when
        state.loading = false
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let current = findSplit(in: host, vertical: false) else { return false }
            return zip(before, current.arrangedSubviews.map(\.frame)).allSatisfy { abs($0.height - $1.height) < 2 }
        }
        let afterSplit = try #require(findSplit(in: host, vertical: false))
        #expect(afterSplit === split)
        for (old, new) in zip(before, afterSplit.arrangedSubviews.map(\.frame)) {
            #expect(abs(old.height - new.height) < 2)
        }
        #expect(afterSplit.arrangedSubviews[0].frame.height > 300)
        window.contentView = nil
        window.close()
    }

    @Test(arguments: [true, false])
    func givenLoadingRun_whenContentLoads_thenInspectorDividerIsPreserved(_ isGraph: Bool) async throws {
        // given
        _ = NSApplication.shared
        let state = PaneState()
        let host = NSHostingView(rootView: PaneFixture(state: state, isGraph: isGraph))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let split = try #require(findSplit(in: host, vertical: true))
        split.setPosition(split.bounds.width - 320, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        let widths = split.arrangedSubviews.map(\.frame.width)
        // when
        state.loading = false
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let current = findSplit(in: host, vertical: true) else { return false }
            return zip(widths, current.arrangedSubviews.map(\.frame.width)).allSatisfy { abs($0 - $1) < 2 }
        }
        let after = try #require(findSplit(in: host, vertical: true))
        #expect(after === split)
        for (old, new) in zip(widths, after.arrangedSubviews.map(\.frame.width)) {
            #expect(abs(old - new) < 2, "Inspector width changed from \(old) to \(new)")
        }
        window.contentView = nil
        window.close()
    }

    private func findSplit(in view: NSView, vertical: Bool) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical == vertical { return split }
        for child in view.subviews {
            if let split = findSplit(in: child, vertical: vertical) { return split }
        }
        return nil
    }
}

// MARK: - PaneState

@MainActor @Observable private final class PaneState {
    var loading = true
}

// MARK: - PaneFixture

private struct PaneFixture: View {
    let state: PaneState
    var isGraph = true
    var body: some View {
        WorkflowRunPanes(isGraph: isGraph, isLoading: state.loading) {
            if state.loading { WorkflowLoadingCanvas() } else { Color.clear }
        } inspector: {
            if state.loading { WorkflowLoadingInspector(isRun: true) } else { Color.clear }
        } activity: {
            if state.loading { WorkflowLoadingActivity() } else { Color.clear }
        }
    }
}
