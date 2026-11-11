import AppKit
import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

// MARK: - Harness

@Observable @MainActor
private final class SheetModel {
    var shown = false
    var stopFocus = 0
    var titleFocus = 0
    var detail = PendingLaunchesFixture.detail("waiting")
}

/// The real detail and confirmation view, with the sheet driven the way the coordinator drives it.
private struct Harness: View {
    @Bindable var model: SheetModel

    var body: some View {
        PendingLaunchesContent(
            presentation: PendingLaunchesFixture.inventory, detail: model.detail,
            stopFocusRequest: model.stopFocus, titleFocusRequest: model.titleFocus,
            actions: .init(stop: { model.shown = true })
        )
        .sheet(isPresented: $model.shown) {
            PendingLaunchStopConfirmationView(
                taskID: PendingLaunchesFixture.detailID,
                onCancel: { model.shown = false; model.stopFocus += 1 },
                onConfirm: { model.shown = false; model.titleFocus += 1 }
            )
        }
    }
}

// MARK: - PendingLaunchStopHostedTests

@MainActor @Suite(.serialized)
struct PendingLaunchStopHostedTests {
    private func mount(_ model: SheetModel) -> (NSWindow, NSHostingView<Harness>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Harness(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    private func settle(_ host: NSView, _ predicate: () -> Bool) async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return predicate()
        }
    }

    // Keyboard and accessibility focus (Cancel initially, Stop after a user cancel) is not observable in an
    // unattended hosted window: neither the first responder nor the accessibility focus is realized for SwiftUI
    // buttons here. It is recorded as unverified; the coordinator and view model tests cover the focus tokens.

    @Test func givenStopShown_whenSheetPresentedThenCancelled_thenRealSheetAttachesAndDetaches() async {
        // given
        let model = SheetModel()
        let (window, host) = mount(model)
        defer { model.shown = false; window.contentView = nil; window.close() }
        await settle(host) { window.contentView != nil }
        // when
        model.shown = true
        await settle(host) { window.attachedSheet != nil }
        // then
        #expect(window.attachedSheet != nil)
        // when
        model.shown = false
        model.stopFocus += 1
        await settle(host) { window.attachedSheet == nil }
        // then
        #expect(window.attachedSheet == nil)
        #expect(model.detail.stop == .enabled)
    }

    @Test func givenSheetShown_whenRequestStopMovesTheDetailOn_thenStopIsGoneAndSheetIsClosed() async {
        // given
        let model = SheetModel()
        let (window, host) = mount(model)
        defer { window.contentView = nil; window.close() }
        model.shown = true
        await settle(host) { window.attachedSheet != nil }
        // when
        model.shown = false
        model.detail = PendingLaunchesFixture.stopDetail("requested")
        model.titleFocus += 1
        await settle(host) { window.attachedSheet == nil }
        // then
        #expect(window.attachedSheet == nil)
        #expect(model.detail.stop == nil)
        #expect(model.detail.kind == .stopRequested)
    }
}
