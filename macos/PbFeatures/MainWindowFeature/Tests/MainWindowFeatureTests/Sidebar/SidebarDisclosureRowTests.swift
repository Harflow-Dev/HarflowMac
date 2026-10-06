import AppKit
@testable import MainWindowFeature
import Observation
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - SidebarDisclosureRowTests

@MainActor struct SidebarDisclosureRowTests {
    @Test func givenVisibleRow_whenCollapsedAndReExpanded_thenItsMeasuredHeightClosesAndReturns() async {
        // given — Reduce Motion deliberately keeps the full row height for its fade fallback.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        _ = NSApplication.shared
        let state = DisclosureFixtureState()
        let host = NSHostingView(rootView: DisclosureFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return host.fittingSize.height > 59 }
        #expect(host.fittingSize.height > 59)
        // when
        state.visible = false
        // then
        await waitUntil { host.layoutSubtreeIfNeeded(); return host.fittingSize.height < 1 }
        #expect(host.fittingSize.height < 1)
        // when
        state.visible = true
        // then
        await waitUntil { host.layoutSubtreeIfNeeded(); return host.fittingSize.height > 59 }
        #expect(host.fittingSize.height > 59)
    }

    @Test func givenRowInNativeSidebarList_whenCollapsedAndRemoved_thenFollowingRowMovesUp() async {
        // given
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        _ = NSApplication.shared
        let state = DisclosureFixtureState()
        let marker = NSView()
        let host = NSHostingView(rootView: DisclosureListFixture(state: state, marker: marker))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return marker.window != nil }
        let before = marker.convert(marker.bounds, to: host).minY
        // when
        state.visible = false
        // then
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return abs(marker.convert(marker.bounds, to: host).minY - before) > 20
        }
        // Native sidebar rows retain a system floor. The final List removal closes that gap.
        #expect(abs(marker.convert(marker.bounds, to: host).minY - before) > 20)
        withAnimation(.easeInOut(duration: 0.2)) { state.present = false }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return abs(marker.convert(marker.bounds, to: host).minY - before) > 50
        }
        #expect(abs(marker.convert(marker.bounds, to: host).minY - before) > 50)
    }

}

@MainActor @Observable private final class DisclosureFixtureState {
    var visible = true
    var present = true
}

private struct DisclosureFixture: View {
    let state: DisclosureFixtureState
    var body: some View {
        SidebarDisclosureRow(isVisible: state.visible, animate: true) {
            Text("Workflow child").frame(width: 280, height: 60)
        }
    }
}

private struct DisclosureListFixture: View {
    let state: DisclosureFixtureState
    let marker: NSView
    var body: some View {
        List {
            if state.present {
                SidebarDisclosureRow(isVisible: state.visible, animate: false) {
                    Text("Workflow child").frame(height: 60)
                }.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            DisclosureMarker(view: marker).frame(height: 20)
        }
.listStyle(.sidebar)
.environment(\.defaultMinListRowHeight, 0)
    }
}

private struct DisclosureMarker: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
