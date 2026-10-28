import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized)
struct QualificationHostedTests {
    @Test func givenAllQualificationStates_whenActualNewSessionHosted_thenCardsRemainInScrollableSheet() async throws {
        // given
        _ = NSApplication.shared
        for state in HarnessQualificationModel.State.allCases {
            let vm = NewSessionViewModelMock(repo: "/fixture/repo", message: "Fixture prompt")
            vm.qualificationCards = [.init(id: "fixture", model: .init(identity: "Fixture harness · fixture version", state: state,
                message: "Fixture qualification state", features: [.init(id: "fixture_feature", result: state.title,
                    reason: String(repeating: "Bounded fixture detail. ", count: 30))]))]
            let host = NSHostingView(rootView: AnyView(NewSessionView(vm).environment(\.hfReduceMotionOverride, true)))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            // when
            await DisplayFrames.waitForPresentedFrame()
            await waitUntil(timeout: 5) {
                host.layoutSubtreeIfNeeded()
                return !descendants(host).compactMap { $0 as? NSScrollView }.isEmpty
            }
            // then
            #expect(host.bounds.width == 760)
            #expect(descendants(host).contains { $0 is NSScrollView })
            if let output = ProcessInfo.processInfo.environment["HARFLOW_QUALIFICATION_RENDER_OUTPUT"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("new-session-\(state.rawValue).png"))
            }
            window.contentView = nil
            window.close()
        }
    }

    @Test func givenMultipleRequiredCandidates_whenActualWorkflowSheetHosted_thenEachHarnessHasItsOwnCard() async throws {
        // given
        let harness = WorkflowTests().makeVM(qualification: QualificationFixture(ready: false, additionalBackend: "second"))
        let vm = harness.sut
        vm.validationSuspended = true
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "Fixture"; vm.loadedName = "Fixture"; vm.savedDefinition = vm.definition; vm.repo = "/fixture/repo"
        vm.prepareLaunch()
        await waitUntil { vm.qualificationCards.count == 2 }
        let host = NSHostingView(rootView: AnyView(WorkflowLaunchSheet(viewModel: vm, isGenerating: false)
            .environment(\.hfReduceMotionOverride, true)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { vm.didDisappear(); window.contentView = nil; window.close() }
        // when
        await DisplayFrames.waitForPresentedFrame()
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return !descendants(host).compactMap { $0 as? NSScrollView }.isEmpty
        }
        // then
        #expect(vm.qualificationCards.map(\.model.identity) == ["Fixture · fixture", "Second · fixture"])
        #expect(!vm.canStartWithPreview)
        if let output = ProcessInfo.processInfo.environment["HARFLOW_QUALIFICATION_RENDER_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("workflow-multiple-failed.png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
