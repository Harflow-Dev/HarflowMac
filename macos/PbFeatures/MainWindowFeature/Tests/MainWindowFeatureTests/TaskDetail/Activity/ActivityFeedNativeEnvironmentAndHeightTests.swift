import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeEnvironmentAndHeightTests {
    @Test func givenInheritedEnvironment_whenRowsAreMeasuredAndDisplayed_thenBothHostsUseItAndNativeHeightMatches() async throws {
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: root(rows: rows(length: 10), state: state)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .environment(\.colorScheme, .dark)
            .environment(\.isEnabled, false))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { state.viewportPositioned }
        let table = try #require(descendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let owner = try #require(table.owner)
        let index = try #require(owner.entries.firstIndex { $0.id == "height-row" })
        let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ActivityFeedNativeCell)
        let displayed = try #require(cell.host)
        let measured = NSHostingView(rootView: owner.root(for: owner.boxes[index]))
        measured.sizingOptions = [.intrinsicContentSize]
        measured.frame.size.width = try #require(table.tableColumns.first?.width)
        for environment in [displayed.rootView.environment, measured.rootView.environment] {
            #expect(environment.layoutDirection == .rightToLeft)
            #expect(environment.locale.identifier == "ar")
            #expect(environment.colorScheme == .dark)
            #expect(!environment.isEnabled)
        }
        #expect(cell.isCoherentNativeMeasurement)
        let nativeHeight = table.rect(ofRow: index).height
        #expect(abs(displayed.fittingSize.height - nativeHeight) < 3)
        #expect(abs(measured.fittingSize.height - nativeHeight) < 3)
        #expect(nativeHeight > 50)
    }

    @Test func givenSameIDTextAndWidthChanges_whenUpdated_thenActualRowHeightChangesAndUnchangedRefreshStaysStable() async throws {
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: root(rows: rows(length: 3), state: state))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { state.viewportPositioned }
        let table = try #require(descendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let owner = try #require(table.owner)
        let index = try #require(owner.entries.firstIndex { $0.id == "height-row" })
        let initialHeight = table.rect(ofRow: index).height
        host.rootView = root(rows: rows(length: 30), state: state)
        await waitUntil(timeout: 5) { table.rect(ofRow: index).height > initialHeight + 50 }
        let grownHeight = table.rect(ofRow: index).height
        #expect(grownHeight > initialHeight + 50)
        let grownKey = owner.boxes[index].measurementKey
        host.rootView = root(rows: rows(length: 30), state: state)
        await Task.yield()
        #expect(owner.boxes[index].measurementKey == grownKey)
        #expect(abs(table.rect(ofRow: index).height - grownHeight) < 3)
        window.setContentSize(CGSize(width: 260, height: 450))
        await waitUntil(timeout: 5) { table.rect(ofRow: index).height > grownHeight + 50 }
        #expect(table.rect(ofRow: index).height > grownHeight + 50)
        #expect(owner.boxes[index].measurementKey != grownKey)
        let scroll = try #require(table.enclosingScrollView)
        #expect(abs(table.bounds.maxY - scroll.documentVisibleRect.maxY) < 3)
    }

    @Test func givenPublicInheritedValues_whenDescendantReadsEnvironment_thenValuesAndOpenURLReachConsumer() async throws {
        let capture = NativeEnvironmentCapture()
        var inherited = EnvironmentValues()
        inherited.locale = Locale(identifier: "ar")
        inherited.layoutDirection = .rightToLeft
        inherited.colorScheme = .dark
        inherited.dynamicTypeSize = .accessibility3
        inherited.isEnabled = false
        inherited.pbReduceMotionOverride = true
        inherited.shimmerReduceMotionOverride = true
        inherited.openURL = OpenURLAction { url in
            capture.openedURL = url
            return .handled
        }
        // Read-only accessibility values belong to each host's system environment, not
        // a detached EnvironmentValues default (CI may have Reduce Motion enabled).
        let systemCapture = NativeEnvironmentCapture()
        let systemHost = NSHostingView(rootView: NativeEnvironmentConsumer(capture: systemCapture)
            .environment(\.openURL, OpenURLAction { _ in .handled }))
        let systemWindow = open(systemHost)
        let host = NSHostingView(rootView: NativeEnvironmentConsumer(capture: capture)
            .modifier(ActivityFeedNativeInheritedEnvironment(environment: inherited)))
        let window = open(host)
        defer {
            window.contentView = nil; window.close()
            systemWindow.contentView = nil; systemWindow.close()
        }
        await waitUntil(timeout: 3) { capture.values != nil && systemCapture.values != nil }
        let actual = try #require(capture.values)
        let system = try #require(systemCapture.values)
        #expect(actual.locale.identifier == "ar")
        #expect(actual.layoutDirection == .rightToLeft)
        #expect(actual.colorScheme == .dark)
        #expect(actual.dynamicTypeSize == .accessibility3)
        #expect(!actual.isEnabled)
        #expect(actual.accessibilityReduceMotion == system.accessibilityReduceMotion)
        #expect(actual.pbReduceMotionOverride == true)
        #expect(actual.shimmerReduceMotionOverride == true)
        #expect(capture.openedURL == URL(string: "https://example.invalid/tool"))
    }

    private func rows(length: Int) -> [ActivityRow] {
        [.single(ConversationTimelineRow(id: "height-row", taskID: "height-task", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "Natural text wrapping determines the native row height. ", count: length),
                seq: 0)), live: false))]
    }

    private func root(rows: [ActivityRow], state: ParallelColumnUIState) -> ActivityFeedView {
        ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
                         horizontalPadding: 12, state: state, onLoadMore: nil)
    }

    private func open(_ host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class NativeEnvironmentCapture {
    var values: EnvironmentValues?
    var openedURL: URL?
}

private struct NativeEnvironmentConsumer: View {
    @Environment(\.self) private var actual
    let capture: NativeEnvironmentCapture

    var body: some View {
        Text("Environment consumer")
            .onAppear {
                capture.values = actual
                actual.openURL(URL(string: "https://example.invalid/tool")!)
            }
    }
}
