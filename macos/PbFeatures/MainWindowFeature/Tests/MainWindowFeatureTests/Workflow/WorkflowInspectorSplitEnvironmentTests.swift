import AppKit
@testable import MainWindowFeature
import Observation
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowInspectorSplitEnvironmentTests {
    @Test func givenParentEnvironment_whenNativePanesMountAndUpdate_thenBothInheritCurrentValues() async {
        // given
        _ = NSApplication.shared
        let state = SplitEnvironmentState()
        let host = NSHostingView(rootView: SplitEnvironmentFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil { state.observed["content"] == "inherited" && state.observed["inspector"] == "inherited" }
        // then
        #expect(state.observed["content"] == "inherited")
        #expect(state.observed["inspector"] == "inherited")
        // when
        state.value = "updated"
        await waitUntil { state.observed["content"] == "updated" && state.observed["inspector"] == "updated" }
        // then
        #expect(state.observed["content"] == "updated")
        #expect(state.observed["inspector"] == "updated")
    }
}

private struct SplitFixtureEnvironmentKey: EnvironmentKey {
    static let defaultValue = "missing"
}

private extension EnvironmentValues {
    var splitFixtureValue: String {
        get { self[SplitFixtureEnvironmentKey.self] }
        set { self[SplitFixtureEnvironmentKey.self] = newValue }
    }
}

@MainActor @Observable private final class SplitEnvironmentState {
    var value = "inherited"
    var observed: [String: String] = [:]
}

private struct SplitEnvironmentFixture: View {
    let state: SplitEnvironmentState
    var body: some View {
        WorkflowInspectorSplit {
            SplitEnvironmentProbe { state.observed["content"] = $0 }
        } inspector: {
            SplitEnvironmentProbe { state.observed["inspector"] = $0 }
        }
        .environment(\.splitFixtureValue, state.value)
    }
}

private struct SplitEnvironmentProbe: View {
    @Environment(\.splitFixtureValue) private var value
    let didRead: (String) -> Void
    var body: some View {
        Text(value)
            .onAppear { didRead(value) }
            .onChange(of: value) { _, current in didRead(current) }
    }
}
