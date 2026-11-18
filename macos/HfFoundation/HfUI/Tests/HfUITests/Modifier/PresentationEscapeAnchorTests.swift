import AppKit
import HfCommon
import HfTestUtilities
@testable import HfUI
import SwiftUI
import Testing

// MARK: - PresentationEscapeAnchorTests

@MainActor @Suite struct PresentationEscapeAnchorTests {
    private func content(_ title: String) -> AlertContent {
        AlertContent(title: title) {
            AlertAction(title: "Cancel", role: .cancel, isDefault: true)
        }
    }

    private func makeWindow() -> (NSWindow, PresentationEscapeAnchor.AnchorView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = PresentationEscapeAnchor.AnchorView()
        window.contentView?.addSubview(anchor)
        return (window, anchor)
    }

    @Test func givenAnchorInWindow_whenPresentationComesReplacesAndGoes_thenMonitorFollowsIt() {
        // given
        let (window, anchor) = makeWindow()
        defer { window.close() }
        #expect(!anchor.isMonitoring)
        // when / then
        anchor.update(presentation: content("First"))
        #expect(anchor.isMonitoring)
        anchor.update(presentation: content("Second"))
        #expect(anchor.isMonitoring)
        #expect(anchor.ownedSheet == nil)
        anchor.update(presentation: nil)
        #expect(!anchor.isMonitoring)
    }

    @Test func givenActivePresentation_whenAnchorLeavesAndReturnsToWindow_thenMonitorIsRemovedThenReinstalled() {
        // given
        let (window, anchor) = makeWindow()
        defer { window.close() }
        anchor.update(presentation: content("Active"))
        #expect(anchor.isMonitoring)
        // when
        anchor.removeFromSuperview()
        // then
        #expect(!anchor.isMonitoring)
        window.contentView?.addSubview(anchor)
        #expect(anchor.isMonitoring)
    }

    @Test func givenActivePresentation_whenDismantled_thenMonitorIsRemoved() {
        // given
        let (window, anchor) = makeWindow()
        defer { window.close() }
        anchor.update(presentation: content("Active"))
        // when
        PresentationEscapeAnchor.dismantleNSView(anchor, coordinator: ())
        // then
        #expect(!anchor.isMonitoring)
    }

    @Test func givenSheetPresentedBeforeThePresentation_whenPresentationStarts_thenItIsNeverOwned() async {
        // given
        let (window, anchor) = makeWindow()
        let sheet = cancelSheet()
        window.beginSheet(sheet, completionHandler: nil)
        defer { window.endSheet(sheet); window.close() }
        // when
        anchor.update(presentation: content("Active"))
        await waitUntil { window.attachedSheet === sheet }
        // then
        #expect(anchor.ownedSheet == nil)
    }

    @Test func givenSheetBeginningAfterThePresentation_whenItsDefaultTitleMatches_thenItIsOwned() async {
        // given
        let (window, anchor) = makeWindow()
        let sheet = cancelSheet()
        defer { window.endSheet(sheet); window.close() }
        anchor.update(presentation: content("Active"))
        // when
        window.beginSheet(sheet, completionHandler: nil)
        await waitUntil { anchor.ownedSheet != nil }
        // then
        #expect(anchor.ownedSheet === sheet)
    }

    private func cancelSheet() -> NSWindow {
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        sheet.contentView?.addSubview(cancel)
        sheet.defaultButtonCell = cancel.cell as? NSButtonCell
        return sheet
    }
}
