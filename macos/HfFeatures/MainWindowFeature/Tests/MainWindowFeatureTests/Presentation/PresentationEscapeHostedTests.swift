import AppKit
import HfCommon
import HfTestUtilities
@testable import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - PresentationEscapeHostedTests

/// Native alert and dialog sheets under the window presentation context; run only through the guarded hosted lane.
@MainActor @Suite(.serialized) struct PresentationEscapeHostedTests {
    @Test(arguments: [false, true])
    func givenCancelDefault_whenEscapePressed_thenCancelRunsOnceAndSheetDismisses(isDialog: Bool) async throws {
        // given
        let probe = ActionProbe()
        let page = host(probe, isDialog: isDialog)
        defer { cleanUp(page) }
        let sheet = try await present(in: page)
        // when
        NSApp.sendEvent(try key(.escape, in: sheet))
        await page.settle { page.window.attachedSheet == nil }
        // then
        #expect(page.window.attachedSheet == nil)
        #expect(probe.cancels == 1)
        #expect(probe.confirms == 0)
    }

    @Test func givenCancelDefault_whenEscapeRepeatsBeforeDismissal_thenCancelStillRunsOnce() async throws {
        // given
        let probe = ActionProbe()
        let page = host(probe, isDialog: false)
        defer { cleanUp(page) }
        let sheet = try await present(in: page)
        // when
        for _ in 0 ..< 3 { NSApp.sendEvent(try key(.escape, in: sheet)) }
        await page.settle { page.window.attachedSheet == nil }
        // then
        #expect(page.window.attachedSheet == nil)
        #expect(probe.cancels == 1)
        #expect(probe.confirms == 0)
    }

    @Test func givenCancelDefault_whenReturnPressed_thenBehaviourIsUnchanged() async throws {
        // given
        let probe = ActionProbe()
        let page = host(probe, isDialog: false)
        defer { cleanUp(page) }
        let sheet = try await present(in: page)
        // when
        NSApp.sendEvent(try key(.returnKey, in: sheet))
        await page.settle { page.window.attachedSheet == nil }
        // then
        #expect(page.window.attachedSheet == nil)
        #expect(probe.cancels == 1)
        #expect(probe.confirms == 0)
    }

    /// Unverified until a run with an unlocked screen: the expectation is AppKit's own Escape-to-cancel-role mapping.
    @Test func givenDefaultWithoutCancelRole_whenEscapePressed_thenNativeCancelRunsOnceAndOurMonitorStaysOff() async throws {
        // given
        let probe = ActionProbe()
        let page = host(probe, isDialog: true, cancelIsDefault: false)
        defer { cleanUp(page) }
        let sheet = try await present(in: page)
        #expect(anchors(in: page).allSatisfy { !$0.isMonitoring })
        // when
        NSApp.sendEvent(try key(.escape, in: sheet))
        await page.settle { page.window.attachedSheet == nil }
        // then
        #expect(page.window.attachedSheet == nil)
        #expect(probe.cancels == 1)
        #expect(probe.confirms == 0)
    }

    @Test func givenNestedSheetOverOwnedSheet_whenEscapePressedInNestedSheet_thenOwnedCancelIsNotRun() async throws {
        // given
        let probe = ActionProbe()
        let page = host(probe, isDialog: false)
        let owned = try await present(in: page)
        let nested = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        nested.isReleasedWhenClosed = false
        owned.beginSheet(nested, completionHandler: nil)
        defer {
            if nested.sheetParent != nil { owned.endSheet(nested) }
            cleanUp(page)
        }
        await page.settle { owned.attachedSheet === nested }
        #expect(owned.attachedSheet === nested)
        // when
        NSApp.sendEvent(try key(.escape, in: nested))
        NSApp.sendEvent(try key(.escape, in: owned))
        await page.settle { true }
        // then
        #expect(probe.cancels == 0)
        #expect(owned.attachedSheet === nested)
        #expect(page.window.attachedSheet === owned)
    }

    @Test func givenForeignSheetAlreadyAttached_whenEscapePressedInIt_thenItIsNeverAdoptedAndCancelIsNotRun() async throws {
        // given
        let probe = ActionProbe()
        let page = host(probe, isDialog: false)
        let foreign = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        foreign.contentView?.addSubview(cancel)
        foreign.defaultButtonCell = cancel.cell as? NSButtonCell
        page.window.beginSheet(foreign, completionHandler: nil)
        defer {
            if foreign.sheetParent != nil { page.window.endSheet(foreign) }
            cleanUp(page)
        }
        await page.settle { page.window.attachedSheet === foreign }
        #expect(page.window.attachedSheet === foreign)
        // when
        await page.settle { page.element("Present") != nil }
        let present = try #require(page.element("Present"))
        #expect(page.press(present))
        await page.settle { true }
        NSApp.sendEvent(try key(.escape, in: foreign))
        await page.settle { true }
        // then
        #expect(probe.cancels == 0)
        #expect(page.window.attachedSheet === foreign)
    }

    @Test func givenTwoWindowsEachWithContext_whenEscapePressedInOne_thenOnlyThatSheetCancels() async throws {
        // given
        let first = ActionProbe()
        let second = ActionProbe()
        let pageA = host(first, isDialog: false)
        let pageB = host(second, isDialog: false)
        defer { cleanUp(pageB); cleanUp(pageA) }
        let sheetA = try await present(in: pageA)
        let sheetB = try await present(in: pageB)
        // when
        NSApp.sendEvent(try key(.escape, in: sheetB))
        await pageB.settle { pageB.window.attachedSheet == nil }
        // then
        #expect(pageB.window.attachedSheet == nil)
        #expect(second.cancels == 1)
        #expect(first.cancels == 0)
        #expect(pageA.window.attachedSheet === sheetA)
    }

    // MARK: Support

    private func host(_ probe: ActionProbe, isDialog: Bool, cancelIsDefault: Bool = true) -> RedesignHost {
        let page = RedesignHost(EscapeHarness(probe: probe, isDialog: isDialog, cancelIsDefault: cancelIsDefault),
                                size: CGSize(width: 700, height: 400))
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return page
    }

    private func cleanUp(_ page: RedesignHost) {
        for _ in 0 ..< 4 {
            guard let sheet = page.window.attachedSheet else { break }
            page.window.endSheet(sheet)
        }
        page.close()
    }

    private func anchors(in page: RedesignHost) -> [PresentationEscapeAnchor.AnchorView] {
        page.descendants.compactMap { $0 as? PresentationEscapeAnchor.AnchorView }
    }

    private func present(in page: RedesignHost) async throws -> NSWindow {
        await page.settle { page.element("Present") != nil }
        #expect(page.press(try #require(page.element("Present"))))
        await page.settle { page.window.attachedSheet != nil }
        let sheet = try #require(page.window.attachedSheet)
        await page.settle { sheet.defaultButtonCell != nil }
        return sheet
    }

    private enum Key { case escape, returnKey }

    private func key(_ key: Key, in window: NSWindow) throws -> NSEvent {
        let escape = key == .escape
        let characters = escape ? "\u{1B}" : "\r"
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: escape ? 53 : 36))
    }
}

// MARK: - ActionProbe

@MainActor private final class ActionProbe {
    var cancels = 0
    var confirms = 0
}

// MARK: - EscapeHarness

private struct EscapeHarness: View {
    @Environment(\.viewEvent) private var viewEvent
    let probe: ActionProbe
    let isDialog: Bool
    let cancelIsDefault: Bool

    var body: some View {
        Button("Present") {
            let content = AlertContent(title: "Discard changes?", description: "Fixture") {
                AlertAction(title: "Discard", role: .destructive, isDefault: !cancelIsDefault) { probe.confirms += 1 }
                AlertAction(title: "Cancel", role: .cancel, isDefault: cancelIsDefault) { probe.cancels += 1 }
            }
            viewEvent.wrappedValue = isDialog ? .dialog(content) : .alert(content)
        }
    }
}
