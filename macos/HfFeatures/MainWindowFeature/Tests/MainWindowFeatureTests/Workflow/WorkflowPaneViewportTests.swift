import AppKit
import HfCommon
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - WorkflowPaneViewportTests

@MainActor @Suite(.serialized) struct WorkflowPaneViewportTests {
    @Test func givenBuilderBesideSidebar_whenWindowResizes_thenActivityHeaderStaysInsideBuilderPane() async throws {
        // given
        _ = NSApplication.shared
        let state = BuilderPaneGeometryState()
        let vm = try QualifiedBuilderFixture.makeVM(name: "Builder")
        QualifiedBuilderFixture.selectBuilderRun(on: vm, taskID: "builder-task")
        let run = try #require(vm.selectedRun)
        let host = NSHostingView(rootView: NavigationSplitView {
            Text("Sidebar")
.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: {
            WorkflowView(vm, builderTaskView: { _, _ in
                AnyView(VStack(spacing: 0) {
                    Text("Activity header")
.frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 50)
                        .background(BuilderPaneGeometryProbe { state.header = $0 })
                    ScrollView { Text(String(repeating: "Activity line\n", count: 100)) }
                }.background(BuilderPaneGeometryProbe { state.pane = $0 }))
            })
        }
.frame(minWidth: 1000, minHeight: 620)
.withPresentationContext())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = host
        defer { vm.didDisappear(); window.contentView = nil; window.close() }
        // when
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.header != nil && state.pane != nil }
        vm.didDisappear()
        vm.selectedRun = run
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 620)] {
            window.setContentSize(size)
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            // then
            let header = try #require(state.header)
            let pane = try #require(state.pane)
            let headerBounds = host.convert(header.bounds, from: header)
            let paneBounds = host.convert(pane.bounds, from: pane)
            #expect(paneBounds.minX >= 239, "Builder activity must remain to the right of the sidebar")
            let canvasScroll = try #require(Self.allViews(host).compactMap { $0 as? WorkflowCanvasScrollProbe }.first?.enclosingScrollView)
            let canvasBounds = host.convert(canvasScroll.bounds, from: canvasScroll)
            #expect(canvasBounds.minX >= 239, "Builder canvas must start at the sidebar edge, not under it")
            #expect(canvasBounds.width > 200, "Builder canvas must receive its budgeted width: \(canvasBounds)")
            #expect(canvasBounds.maxX <= paneBounds.minX + 1)
            #expect(abs(headerBounds.minX - paneBounds.minX) < 1)
            #expect(headerBounds.maxX <= paneBounds.maxX + 1)
            #expect(headerBounds.minY >= paneBounds.minY - 1)
            #expect(headerBounds.maxY <= paneBounds.maxY + 1)
            #expect(paneBounds.maxX <= host.bounds.maxX + 1)
        }
    }

    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    @Test func givenPresentationEnvironment_whenHostedPaneUpdates_thenBindingsPreferencesAndStateSurvive() async throws {
        // given
        _ = NSApplication.shared
        let state = ViewportEnvironmentState()
        let scratch = ScratchDefaults(label: "harflow-host-fixture")
        let defaults = scratch.defaults
        defaults.set(42, forKey: "fixture-value")
        defer { scratch.remove() }
        let host = NSHostingView(rootView: ViewportEnvironmentFixture(state: state).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.read == 1 }
        let identity = try #require(state.identities.first)
        state.version = 2
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.read == 2 }
        // then
        #expect(state.read == 2)
        #expect(state.reduceMotion == state.outerReduceMotion)
        #expect(state.isDark)
        #expect(state.storedValue == 42)
        #expect(state.events == [1, 2])
        #expect(state.identities == [identity])
    }
}

// MARK: - BuilderPaneGeometryState

@MainActor private final class BuilderPaneGeometryState {
    var header: NSView?
    var pane: NSView?
}

// MARK: - BuilderPaneGeometryProbe

private struct BuilderPaneGeometryProbe: NSViewRepresentable {
    let didCreate: (NSView) -> Void
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        didCreate(view)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - ViewportEnvironmentState

@MainActor @Observable private final class ViewportEnvironmentState {
    var version = 1
    var read = 0
    var reduceMotion = false
    var outerReduceMotion = false
    var isDark = false
    var storedValue = 0
    var events: [Int] = []
    var identities: Set<UUID> = []
}

// MARK: - ViewportEnvironmentFixture

private struct ViewportEnvironmentFixture: View {
    let state: ViewportEnvironmentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ViewportEnvironmentProbe { state.outerReduceMotion = reduceMotion }.frame(height: 0)
            WorkflowPaneViewport { ViewportEnvironmentChild(version: state.version, state: state) }
                .environment(\.colorScheme, .dark)
                .environment(\.viewEvent, Binding(get: { .none }, set: { _ in state.events.append(state.version) }))
        }
    }
}

// MARK: - ViewportEnvironmentChild

private struct ViewportEnvironmentChild: View {
    let version: Int
    let state: ViewportEnvironmentState
    @State private var identity = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.viewEvent) private var viewEvent
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("fixture-value") private var storedValue = 0

    var body: some View {
        ViewportEnvironmentProbe {
            guard state.read != version else { return }
            state.read = version
            state.reduceMotion = reduceMotion
            state.isDark = colorScheme == .dark
            state.storedValue = storedValue
            state.identities.insert(identity)
            viewEvent.wrappedValue = .incident(source: "fixture", message: "Fixture failure", retry: nil)
        }
    }
}

// MARK: - ViewportEnvironmentProbe

private struct ViewportEnvironmentProbe: NSViewRepresentable {
    let observe: () -> Void
    func makeNSView(context _: Context) -> NSView { NSView() }
    func updateNSView(_: NSView, context _: Context) { observe() }
}
