import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelGroupLoadingHostedTests

/// The loading skeleton of a Parallel group in the production shell: the same lane frames as the loaded group, one
/// accessibility element, a disabled composer and disabled toolbar buttons. Needs the AppKit host.
@MainActor @Suite(.serialized) struct ParallelGroupLoadingHostedTests {
    @MainActor @Observable final class LoadedVM: ParallelViewModel {
        var groupName = "release"
        var statusSummary: String?
        var showPrompt = false
        var canCancelAll = true
        var isEmpty = false
        var columns: [ParallelColumnModel] = ParallelViewModelMock.sampleColumns().map { column in
            // A lane with a way to send has no "messaging unavailable" note under its composer, as in a real group.
            var lane = column
            lane.onSubmitMessage = { _, _ in true }
            return lane
        }

        var horizontalPosition: ParallelViewportPosition? = ParallelViewportPosition()
        func didAppear() {}
        func didDisappear() {}
        func didTapViewPrompt() {}
        func didTapCancelAll() {}
    }

    private struct Measured {
        let document: CGRect
        let field: CGRect?
    }

    private func mount(loading: Bool, size: CGSize) async -> (NSWindow, MainWindowNavigationCoordinatorMock) {
        _ = NSApplication.shared
        let coordinator = MainWindowNavigationCoordinatorMock()
        let columns = LoadedVM().columns.count
        coordinator.parallelBuilder = { _ in
            let view = loading ? AnyView(ParallelLoadingContent(laneCount: columns)) : AnyView(ParallelView(LoadedVM(), initiallyPrepared: true))
            return view.id("g").eraseToAnyView()
        }
        coordinator.selection = .group("release")
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator).environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: size.width, height: size.height))
        var passes = 0
        await waitUntil(timeout: 10) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= 120
        }
        return (window, coordinator)
    }

    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    private func measure(_ window: NSWindow) -> Measured? {
        guard let content = window.contentView else { return nil }
        let all = views(content)
        guard let scroll = all.compactMap({ $0 as? NSScrollView }).first(where: { $0.hasHorizontalScroller && ($0.documentView?.frame.height ?? 0) > 300 }),
              let document = scroll.documentView else { return nil }
        // The composer is the lowest text field in the first lane.
        let fields = views(document)
.filter { ($0 is NSTextField || $0 is NSTextView) && !$0.isHidden && $0.frame.height > 0 && $0.frame.height < 60 }
            .map { $0.convert($0.bounds, to: nil) }
        let field = fields.min { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        return Measured(document: document.convert(document.bounds, to: nil), field: field)
    }

    private func subtree(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        while let next = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: kids) }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func label(_ window: NSWindow, _ text: String) -> NSObject? {
        let roots: [NSObject] = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap(\.self)
        return roots.flatMap(subtree).first { object in
            ["accessibilityLabel", "accessibilityValue"].contains { key in
                let selector = NSSelectorFromString(key)
                return object.responds(to: selector) && (object.perform(selector)?.takeUnretainedValue() as? String) == text
            }
        }
    }

    @Test(arguments: [CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 620)])
    func givenTheLoadingSkeleton_whenComparedWithTheLoadedGroup_thenTheLaneFramesMatchWithinHalfAPoint(size: CGSize) async throws {
        // given / when
        let (loadingWindow, _) = await mount(loading: true, size: size)
        defer { loadingWindow.contentViewController = nil; loadingWindow.close() }
        let (loadedWindow, _) = await mount(loading: false, size: size)
        defer { loadedWindow.contentViewController = nil; loadedWindow.close() }
        let loading = try #require(measure(loadingWindow), "no lane row while loading at \(size)")
        let loaded = try #require(measure(loadedWindow), "no lane row when loaded at \(size)")

        // then
        #expect(abs(loading.document.minX - loaded.document.minX) <= 0.5, "lane row x: \(loading.document) vs \(loaded.document)")
        #expect(abs(loading.document.width - loaded.document.width) <= 0.5, "lane row width: \(loading.document) vs \(loaded.document)")
        #expect(abs(loading.document.height - loaded.document.height) <= 0.5, "lane row height: \(loading.document) vs \(loaded.document)")
        let loadingField = try #require(loading.field, "no composer field while loading")
        let loadedField = try #require(loaded.field, "no composer field when loaded")
        #expect(abs(loadingField.minY - loadedField.minY) <= 0.5, "composer y: \(loadingField) vs \(loadedField)")
        #expect(abs(loadingField.minX - loadedField.minX) <= 0.5, "composer x: \(loadingField) vs \(loadedField)")
    }

    @Test func givenTheLoadingSkeleton_whenMounted_thenItIsOneAccessibilityElementWithNoGroupText() async throws {
        // given / when
        let (window, _) = await mount(loading: true, size: CGSize(width: 1280, height: 800))
        defer { window.contentViewController = nil; window.close() }

        // then
        #expect(label(window, "Loading Parallel group") != nil)
        let content = window.contentView.map(subtree) ?? []
        let texts = content.compactMap { object -> String? in
            let selector = NSSelectorFromString("accessibilityLabel")
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
        }
        #expect(!texts.contains("Message"), "the composer is inside the one element, not separate")
        #expect(!texts.contains { $0.contains("Audit what the preload bridge exposes") }, "no lane text while loading")
    }

    @Test func givenTheLoadingSkeleton_whenMounted_thenTheComposerIsRealAndDisabled() async throws {
        // given / when
        let (window, _) = await mount(loading: true, size: CGSize(width: 1280, height: 800))
        defer { window.contentViewController = nil; window.close() }

        // then — checked in the view hierarchy, not the accessibility tree (the skeleton is one element)
        let measured = try #require(measure(window))
        #expect(measured.field != nil, "the real composer field is present")
        let editable = views(try #require(window.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(editable.allSatisfy { !$0.isEnabled }, "no editable field is enabled while loading")
    }

    @Test func givenTheLoadingSkeleton_whenMounted_thenBothToolbarButtonsAreDisabled() async throws {
        // given / when
        let (window, _) = await mount(loading: true, size: CGSize(width: 1280, height: 800))
        defer { window.contentViewController = nil; window.close() }

        // then
        let prompt = try #require(label(window, "View prompt"))
        let cancel = try #require(label(window, "Cancel all"))
        #expect(TaskStoppingHostedTests.isEnabled(prompt) == false)
        #expect(TaskStoppingHostedTests.isEnabled(cancel) == false)
    }
}
