import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TaskDetailNavigationChromeTests {
    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)])
    func givenTaskSelection_whenDeferredContentReplacesSkeleton_thenWindowAndContentOriginsStayStable(size: CGSize) async throws {
        _ = NSApplication.shared
        let harness = TaskDetailVMTests().makeSUT()
        harness.detailBox.value = TaskDetailVMTests().task()
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 200, y: 200), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: root(harness.sut, revision: 0))
        host.sceneBridgingOptions = .all
        window.contentViewController = host
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        await waitUntil { window.layoutIfNeeded(); return window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "task-detail.inspector" } == true }
        let baselineFrame = window.frame
        let baselineLayout = window.contentLayoutRect
        host.rootView = root(harness.sut, revision: 1)
        var frames: [CGRect] = []
        var layouts: [CGRect] = []
        var identifiers: Set<String> = []
        var minimumHeights: [CGFloat] = []
        for _ in 0 ..< 80 {
            window.layoutIfNeeded()
            minimumHeights.append(host.view.fittingSize.height)
            frames.append(window.frame)
            layouts.append(window.contentLayoutRect)
            identifiers.formUnion(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])
            try await Task.sleep(for: .milliseconds(2))
        }
        let frameMovement = frames.map { abs($0.minY - baselineFrame.minY) }.max() ?? 0
        let contentMovement = layouts.map { abs($0.minY - baselineLayout.minY) + abs($0.height - baselineLayout.height) }.max() ?? 0
        print("Deferred navigation chrome: window delta \(frameMovement), content delta \(contentMovement)")
        print("Minimum height \(minimumHeights.max() ?? 0), toolbar slots \(identifiers.sorted())")
        #expect(frameMovement < 1)
        #expect(contentMovement < 1)
        #expect((minimumHeights.max() ?? 0) <= size.height, "Deferred loading must not demand a taller scene window")
    }

    private func root(_ model: TaskDetailVM, revision: Int) -> some View {
        NavigationSplitView {
            Text("Synthetic sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            TaskDetailView(model).id(revision)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .withPresentationContext()
    }
}
