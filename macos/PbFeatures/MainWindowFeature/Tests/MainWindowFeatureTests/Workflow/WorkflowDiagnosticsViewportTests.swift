import AppKit
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WorkflowDiagnosticsViewportTests

@MainActor @Suite(.serialized) struct WorkflowDiagnosticsViewportTests {
    @Test func givenCompactDiagnostics_whenLoadingBecomesLoaded_thenEveryLayoutUsesIntrinsicHeight() async throws {
        // given
        let fixture = DiagnosticsFixture(size: CGSize(width: 1000, height: 700))
        defer { fixture.close() }
        fixture.state.loading = true
        await fixture.settle()
        let marker = try #require(fixture.marker())
        #expect(abs(marker.bounds.height - 47) < 1)
        // when
        fixture.state.heights.removeAll()
        fixture.state.loading = false
        // then: inspect each committed layout, not only the final size after delayed measurement.
        for _ in 0 ..< 4 {
            await Task.yield()
            fixture.host.layoutSubtreeIfNeeded()
            #expect((fixture.marker()?.bounds.height ?? 0) <= 47.5, "A compact first frame must not reserve 180 points")
        }
        await fixture.settle()
        #expect(abs((fixture.marker()?.bounds.height ?? 0) - fixture.state.contentHeight) < 1)
        #expect(!fixture.state.heights.isEmpty)
        #expect(fixture.state.heights.allSatisfy { $0 <= 47.5 })
    }

    @Test(arguments: [CGSize(width: 1000, height: 700), CGSize(width: 1000, height: 300)])
    func givenLongDiagnostics_whenLaidOut_thenHeightIsCappedAndContentCanScroll(_ size: CGSize) async throws {
        // given
        let fixture = DiagnosticsFixture(size: size)
        defer { fixture.close() }
        fixture.state.contentHeight = 600
        // when
        await fixture.settle()
        let marker = try #require(fixture.marker())
        let cap = min(180, size.height * 0.3)
        // then
        #expect(abs(marker.bounds.height - cap) < 1)
        let scroll = try #require(descendants(of: fixture.host).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.documentView?.bounds.height ?? 0 > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y > 0)
    }

    @Test func givenRealRunStatus_whenFirstLoadedAndDiagnosticsGrow_thenFramesFitOrCapSynchronously() async throws {
        // given
        let fixture = DiagnosticsFixture(size: CGSize(width: 1000, height: 700))
        defer { fixture.close() }
        let vm = WorkflowPreview.make(run: true)
        var raw = try #require(vm.selectedRun?.raw)
        raw["status"] = .string("cancelled")
        vm.selectedRun = WorkflowRunModel(raw: raw)
        fixture.state.viewModel = vm
        fixture.state.loading = true
        await fixture.settle()
        fixture.state.heights.removeAll()
        // when
        fixture.state.loading = false
        await fixture.settle()
        // then
        let compactHeight = try #require(fixture.marker()?.bounds.height)
        print("Native real compact diagnostics height: \(compactHeight); transition frames: \(fixture.state.heights)")
        #expect(compactHeight < 70)
        #expect(!fixture.state.heights.isEmpty)
        #expect(fixture.state.heights.allSatisfy { $0 < 70 }, "Every first layout must fit compact run diagnostics")
        // when
        raw["pending"] = .array((0 ..< 80).map { _ in .object(["decision_attempts": .number(1)]) })
        fixture.state.heights.removeAll()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await fixture.settle()
        // then
        #expect(abs((fixture.marker()?.bounds.height ?? 0) - 180) < 1)
        #expect(fixture.state.heights.allSatisfy { $0 <= 180.5 })
        let scroll = try #require(descendants(of: fixture.host).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.documentView?.bounds.height ?? 0 > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y > 0)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

// MARK: - DiagnosticsFixture

@MainActor private final class DiagnosticsFixture {
    let state = DiagnosticsFixtureState()
    let host: NSHostingView<DiagnosticsFixtureView>
    let window: NSWindow

    init(size: CGSize) {
        _ = NSApplication.shared
        self.host = NSHostingView(rootView: DiagnosticsFixtureView(state: state))
        self.window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
    }

    func marker() -> NSView? { findMarker(in: host) }
    private func findMarker(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "diagnostics-viewport" { return view }
        return view.subviews.compactMap(findMarker).first
    }

    func settle() async {
        await waitUntil { host.layoutSubtreeIfNeeded(); return marker()?.bounds.height ?? 0 > 0 }
        await Task.yield()
        host.layoutSubtreeIfNeeded()
    }

    func close() { window.contentView = nil; window.close() }
}

// MARK: - DiagnosticsFixtureState

@MainActor @Observable private final class DiagnosticsFixtureState {
    var loading = false
    var contentHeight: CGFloat = 32
    var viewModel: WorkflowVM?
    @ObservationIgnored var heights: [CGFloat] = []
}

// MARK: - DiagnosticsFixtureView

private struct DiagnosticsFixtureView: View {
    let state: DiagnosticsFixtureState
    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                Group {
                    if state.loading {
                        Color.clear.frame(height: 47)
                    } else {
                        WorkflowDiagnosticsViewport(maximumHeight: min(180, viewport.size.height * 0.3)) {
                            if let viewModel = state.viewModel {
                                WorkflowRunStatus(viewModel: viewModel)
                            } else {
                                Color.gray.frame(height: state.contentHeight)
                            }
                        }
                    }
                }.background(DiagnosticsGeometryMarker(state: state))
                Color.clear.frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - DiagnosticsGeometryMarker

private struct DiagnosticsGeometryMarker: NSViewRepresentable {
    let state: DiagnosticsFixtureState
    func makeNSView(context _: Context) -> NSView {
        let view = DiagnosticsRecordingView()
        view.record = { state.heights.append($0) }
        view.identifier = NSUserInterfaceItemIdentifier("diagnostics-viewport")
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - DiagnosticsRecordingView

@MainActor private final class DiagnosticsRecordingView: NSView {
    var record: ((CGFloat) -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.height > 0 { record?(newSize.height) }
    }

    override func layout() {
        super.layout()
        if bounds.height > 0 { record?(bounds.height) }
    }
}
