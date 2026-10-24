import AppKit
import Combine
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import SwiftUI
import Testing

/// Opt-in captures of the production preference surfaces and selector layouts.
@MainActor @Suite(.serialized)
struct NativePreferenceCaptureTests {
    @Test func givenProductionPreferenceViews_whenCaptured_thenFooterAndSelectorsRemainVisible() async throws {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_PREFERENCES_CAPTURE_DIR"], !path.isEmpty else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let sidebar = SidebarView(SidebarViewModelMock())
            .frame(width: 240, height: 696)
        let sessionVM = makeSessionVM()
        sessionVM.didChangeRepo("/tmp")
        sessionVM.didChangeMessage("Review the repository")
        sessionVM.didAppear()
        let session = NewSessionView(sessionVM).frame(width: 760, height: 740)
        let workflowVM = WorkflowPreview.make()
        workflowVM.name = "Session reliability"
        workflowVM.loadedName = workflowVM.name
        workflowVM.savedDefinition = workflowVM.definition
        workflowVM.selectNode("implementation")
        workflowVM.agentUsageSnapshot = AgentUsageSnapshot(counts: [
            AgentUsageIdentity(backend: "codex", model: "gpt-5"): 5,
            AgentUsageIdentity(backend: "claude", model: "opus"): 2
        ])
        let workflow = WorkflowView(workflowVM).frame(width: 1200, height: 740)

        let fixtures: [(String, AnyView, CGSize)] = [
            ("sidebar", AnyView(sidebar), CGSize(width: 240, height: 696)),
            ("new-session", AnyView(session), CGSize(width: 760, height: 740)),
            ("workflow", AnyView(workflow), CGSize(width: 1200, height: 740))
        ]
        for (name, view, size) in fixtures {
            for dark in [false, true] {
                let data = try await capture(view, size: size, dark: dark)
                try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                #expect(data.count > 20_000, "\(name) capture is suspiciously small")
            }
        }
        workflowVM.didDisappear()
    }

    private func makeSessionVM() -> NewSessionVM {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        let catalog = BackendCatalog(entries: [
            BackendCatalogEntry(backend: "claude", installed: true),
            BackendCatalogEntry(backend: "codex", installed: true)
        ], state: .available)
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).tasks.willReturn([])
        given(useCase).backendCatalogPublisher().willReturn(Just(catalog).eraseToAnyPublisher())
        let usage = AgentUsageSnapshot(counts: [
            AgentUsageIdentity(backend: "codex", model: "gpt-5"): 4,
            AgentUsageIdentity(backend: "claude", model: "opus"): 2
        ])
        given(useCase).agentUsageSnapshot.willReturn(usage)
        given(useCase).agentUsagePublisher().willReturn(Just(usage).eraseToAnyPublisher())
        given(useCase).models(for: .any).willProduce { backend in
            backend == "codex" ? [ModelOption(value: "gpt-5", label: "GPT 5"), ModelOption(value: "mini", label: "Mini")] : []
        }
        return NewSessionVM(useCase: useCase, routing: routing)
    }

    private func capture(_ view: AnyView, size: CGSize, dark: Bool) async throws -> Data {
        let controller = NSHostingController(rootView: view
            .environment(\.hfReduceMotionOverride, true)
            .preferredColorScheme(dark ? .dark : .light))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        for _ in 0 ..< 6 { await DisplayFrames.waitForPresentedFrame() }
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CaptureError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CaptureError.noBitmap
        }
        return data
    }

    private enum CaptureError: Error { case noBitmap }
}
