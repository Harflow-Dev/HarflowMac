import AppKit
@testable import MainWindowFeature
import Observation
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WorkflowScreenLayoutTests

@MainActor @Suite struct WorkflowScreenLayoutTests {
    @Test(arguments: ["failure", "preparing", "loaded"])
    func givenWorkflowState_whenLaidOutAndThenLoaded_thenHeaderStaysAtTop(_ kind: String) async throws {
        // given
        _ = NSApplication.shared
        let state = ScreenLayoutState(kind: kind)
        let size = CGSize(width: 1440, height: 1440)
        let host = NSHostingView(rootView: ScreenLayoutFixture(state: state))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.probe?.bounds.height == 90 }
        let probe = try #require(state.probe)
        let before = host.convert(probe.bounds, from: probe)
        let top = host.isFlipped ? before.minY : host.bounds.height - before.maxY
        // then
        #expect(abs(top) < 1, "Header was centered at \(top) instead of pinned to the top")
        state.kind = "loaded"
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let after = host.convert(probe.bounds, from: probe)
        #expect(abs(after.minY - before.minY) < 1)
        #expect(abs(after.height - before.height) < 1)
    }
}

// MARK: - ScreenLayoutState

@MainActor @Observable private final class ScreenLayoutState {
    var kind: String
    var probe: NSView?
    init(kind: String) { self.kind = kind }
}

// MARK: - ScreenLayoutFixture

private struct ScreenLayoutFixture: View {
    let state: ScreenLayoutState
    var body: some View {
        WorkflowScreenLayout {
            Text("Workflow header / Graph / Parallel")
.frame(maxWidth: .infinity)
.frame(height: 90)
                .background(HeaderGeometryProbe { state.probe = $0 })
        } content: {
            switch state.kind {
            case "failure": ContentUnavailableView("Workflow could not be loaded", systemImage: "exclamationmark.triangle")
            case "preparing": WorkflowLoadingView(isRun: true)
            default: Color.clear
            }
        }
    }
}

// MARK: - HeaderGeometryProbe

private struct HeaderGeometryProbe: NSViewRepresentable {
    let didCreate: (NSView) -> Void
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        didCreate(view)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
