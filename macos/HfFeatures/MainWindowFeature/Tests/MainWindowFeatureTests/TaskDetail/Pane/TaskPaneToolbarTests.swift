//
//  TaskPaneToolbarTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskPaneToolbarTests

/// The window toolbar of the standalone mount: its presenter is re-evaluated by a pane toggle and not by metadata
/// or a resize, and its inspector item reads "right pane" on the standalone mount only.
@MainActor @Suite(.serialized) struct TaskPaneToolbarTests {
    private static let conversation = "conv"

    /// Does what the window shell does: maps the width to a band and writes it into the layout state on a crossing.
    private struct BandHost<Content: View>: View {
        @State private var layout = TopBarLayoutState()
        let content: Content
        init(@ViewBuilder content: () -> Content) { self.content = content() }
        var body: some View {
            content
                .onGeometryChange(for: TopBarWidthBand.self) { TopBarWidthBand(width: $0.size.width) } action: { layout.setBand($0) }
                .environment(\.topBarLayout, layout)
        }
    }

    @MainActor private final class Fixture {
        let harness = TaskDetailVMTests().makeSUT()
        let store = TaskPaneStateStore()
        let window: NSWindow
        var evaluations = 0
        private var controller: NSHostingController<AnyView>!

        private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        private let previousEnhanced: Any?

        init(chrome: TaskDetailChrome, width: CGFloat = 1000) {
            _ = NSApplication.shared
            // The toolbar's SwiftUI content only builds its accessibility tree for an assistive client.
            self.previousEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
            var raw = TaskDetailVMTests().task().raw
            raw["started_at"] = .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90)))
            harness.detailBox.value = TaskInfo(.object(raw))
            self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let binding = chrome == .standalone ? TaskPaneBinding(store: store, conversationID: TaskPaneToolbarTests.conversation) : nil
            let defaults = UserDefaults(suiteName: "TaskPaneToolbar-\(UUID().uuidString)")!
            self.controller = NSHostingController(rootView: AnyView(BandHost {
                NavigationStack {
                    TaskDetailView(harness.sut, chrome: chrome, paneBinding: binding, transcriptStyle: .transcript,
                                   onToolbarEvaluation: { [weak self] in self?.evaluations += 1 })
                }
            }
            .withPresentationContext()
            .defaultAppStorage(defaults)
            .environment(\.hfReduceMotionOverride, true)))
            controller.sceneBridgingOptions = .all
            window.contentViewController = controller
            window.orderFront(nil)
        }

        func close() {
            window.contentViewController = nil
            window.close()
            NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
        }

        func pump() {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }

        func settle() async {
            await waitUntil(timeout: 8) {
                pump()
                return harness.sut.task != nil && harness.sut.didSubscribe && evaluations > 0
                    && inspectorItem?.view != nil
            }
            if let acquisition = harness.sut.memberLeaseAcquisition { await acquisition.value }
            // Quiet: three consecutive passes with the same evaluation count.
            var previous = -1
            var stable = 0
            await waitUntil(timeout: 8) {
                pump()
                if evaluations == previous { stable += 1 } else { previous = evaluations; stable = 0 }
                return stable >= 10
            }
        }

        var inspectorItem: NSToolbarItem? {
            window.toolbar?.items.first { $0.itemIdentifier.rawValue == "task-detail.inspector" }
        }

        /// Every string the inspector item exposes: tool tip and accessibility labels through its view tree.
        var inspectorLabels: Set<String> {
            guard let item = inspectorItem else { return [] }
            var labels = Set<String>()
            if !item.toolTip.isNilOrEmpty, let tip = item.toolTip { labels.insert(tip) }
            func visit(_ view: NSView) {
                if let tip = view.toolTip, !tip.isEmpty { labels.insert(tip) }
                if let label = view.accessibilityLabel(), !label.isEmpty { labels.insert(label) }
                for child in view.accessibilityChildren() ?? [] {
                    if let element = child as? NSObject, element.responds(to: NSSelectorFromString("accessibilityLabel")),
                       let label = element.perform(NSSelectorFromString("accessibilityLabel"))?.takeUnretainedValue() as? String,
                       !label.isEmpty { labels.insert(label) }
                }
                for sub in view.subviews { visit(sub) }
            }
            if let view = item.view { visit(view) }
            return labels
        }
    }

    // MARK: - Re-evaluation

    @Test func givenTheStandaloneToolbar_whenMetadataChangesAndTheWindowResizesWithinABand_thenThePresenterIsNotReevaluated() async throws {
        // given
        let fixture = Fixture(chrome: .standalone, width: 1200)
        defer { fixture.close() }
        await fixture.settle()
        let baseline = fixture.evaluations
        #expect(baseline > 0)
        let itemIDs = (fixture.window.toolbar?.items ?? []).map(ObjectIdentifier.init)

        // when — task metadata changes
        for revision in 1 ... 3 {
            var raw = try #require(fixture.harness.sut.task?.raw)
            raw["summary"] = .string("Activity revision \(revision)")
            raw["num_turns"] = .number(Double(revision))
            fixture.harness.detailBox.value = TaskInfo(.object(raw))
            fixture.harness.tasksSubject.send([try #require(fixture.harness.detailBox.value)])
            await waitUntil { fixture.harness.sut.task?.summary == "Activity revision \(revision)" }
            fixture.pump()
        }

        // when — the window resizes inside the 1100 to 1279 band, which the pane's 900 point threshold does not touch
        for width in [1250.0, 1100.0, 1279.0, 1150.0, 1200.0] {
            fixture.window.setContentSize(NSSize(width: width, height: 700))
            for _ in 0 ..< 15 { fixture.pump() }
        }

        // then
        #expect(fixture.evaluations == baseline)
        #expect(itemIDs == (fixture.window.toolbar?.items ?? []).map(ObjectIdentifier.init))
    }

    @Test func givenTheStandaloneToolbar_whenTheWindowCrossesTheNarrowEdge_thenThePresenterIsReevaluatedEachCrossing() async {
        // given
        let fixture = Fixture(chrome: .standalone, width: 1200)
        defer { fixture.close() }
        await fixture.settle()
        var baseline = fixture.evaluations

        // when — into the narrow band
        fixture.window.setContentSize(NSSize(width: 1000, height: 700))
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }

        // then — the chips draw their narrow form
        #expect(fixture.evaluations > baseline)
        await fixture.settle()
        baseline = fixture.evaluations

        // when — resizes inside the narrow band
        for width in [700.0, 900.0, 1099.0, 800.0] {
            fixture.window.setContentSize(NSSize(width: width, height: 700))
            for _ in 0 ..< 15 { fixture.pump() }
        }

        // then
        #expect(fixture.evaluations == baseline)

        // when — back across the edge
        fixture.window.setContentSize(NSSize(width: 1200, height: 700))
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }

        // then
        #expect(fixture.evaluations > baseline)
    }

    @Test func givenTheStandaloneToolbar_whenThePaneIsToggled_thenThePresenterIsReevaluatedEachTime() async {
        // given
        let fixture = Fixture(chrome: .standalone)
        defer { fixture.close() }
        await fixture.settle()
        var baseline = fixture.evaluations

        // when / then
        fixture.store.setOpenChoice(.open, for: Self.conversation)
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }
        #expect(fixture.evaluations > baseline)

        baseline = fixture.evaluations
        fixture.store.setOpenChoice(.closed, for: Self.conversation)
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }
        #expect(fixture.evaluations > baseline)
    }

    @Test func givenAnOpenPaneThePersonChose_whenTheWindowResizesWithinTheNarrowBand_thenThePresenterIsNotReevaluated() async {
        // given
        let fixture = Fixture(chrome: .standalone)
        defer { fixture.close() }
        fixture.store.setOpenChoice(.open, for: Self.conversation)
        await fixture.settle()
        let baseline = fixture.evaluations

        // when
        for width in [700.0, 1099.0, 800.0, 1000.0] {
            fixture.window.setContentSize(NSSize(width: width, height: 700))
            for _ in 0 ..< 15 { fixture.pump() }
        }

        // then — a chosen pane stays open at every width and no band edge was crossed, so the toolbar is not re-evaluated
        #expect(fixture.evaluations == baseline)
    }

    // MARK: - Label

    @Test func givenTheStandaloneToolbar_whenThePaneIsClosedThenOpen_thenTheInspectorItemReadsShowThenHideRightPane() async {
        // given
        let fixture = Fixture(chrome: .standalone)
        defer { fixture.close() }
        await fixture.settle()
        let closedLabels = fixture.inspectorLabels

        // when
        let baseline = fixture.evaluations
        fixture.store.setOpenChoice(.open, for: Self.conversation)
        await waitUntil { fixture.pump(); return fixture.evaluations > baseline }
        await waitUntil { fixture.pump(); return fixture.inspectorLabels.contains("Hide right pane") }
        let openLabels = fixture.inspectorLabels

        // then
        print("TOOLBAR labels closed \(closedLabels) open \(openLabels)")
        #expect(closedLabels.contains("Show right pane"))
        #expect(!closedLabels.contains("Show event details") && !closedLabels.contains("Hide event details"))
        #expect(openLabels.contains("Hide right pane"))
        #expect(!openLabels.contains("Hide event details"))
    }

    @Test func givenTheGroupToolbar_whenRead_thenTheInspectorItemKeepsTheEventDetailsWording() async {
        // given
        let fixture = Fixture(chrome: .group)
        defer { fixture.close() }
        await fixture.settle()

        // when
        let labels = fixture.inspectorLabels

        // then — the legacy pane starts expanded
        print("TOOLBAR group labels \(labels)")
        #expect(labels.contains("Hide event details"))
        #expect(!labels.contains("Hide right pane") && !labels.contains("Show right pane"))
    }

    @Test func givenTheSnapshot_whenOnlyTheRightPaneFlagDiffers_thenTheSnapshotsDiffer() {
        // given
        let mock = TaskDetailViewModelMock()
        let task = mock.task!

        // when
        let legacy = TaskDetailToolbarSnapshot(mock, task: task, showsInspector: true)
        let pane = TaskDetailToolbarSnapshot(mock, task: task, showsInspector: true, isRightPane: true)

        // then
        #expect(legacy != pane)
        #expect(!legacy.isRightPane && pane.isRightPane)
        #expect(pane == TaskDetailToolbarSnapshot(mock, task: task, showsInspector: true, isRightPane: true))
    }
}

private extension String? {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
