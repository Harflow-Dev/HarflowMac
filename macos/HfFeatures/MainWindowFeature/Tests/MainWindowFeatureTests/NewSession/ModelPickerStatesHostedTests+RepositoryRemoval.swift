//
//  ModelPickerStatesHostedTests+RepositoryRemoval.swift
//  MainWindowFeatureTests
//

import AppKit
import Foundation
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - RepositoryComposerRemoval

/// How the composer leaves the window while the field editor holds bytes the view model has not seen.
enum RepositoryComposerRemoval: CaseIterable, Sendable {
    /// SwiftUI removes `NewSessionView` from the same hosting view, the production teardown path.
    case swiftUIRemoval
    /// The window's content view is replaced, an AppKit-level teardown that SwiftUI does not drive. Judged by the same
    /// oracle as SwiftUI removal; dismantle is recorded only.
    case contentViewSwap
}

// MARK: - ComposerRootFlag

@MainActor @Observable
final class ComposerRootFlag {
    var isPresented = true
}

/// Test-only root that can stop rendering `NewSessionView` inside the same hosting view.
struct RemovableComposerRoot<VM: NewSessionViewModel>: View {
    let viewModel: VM
    let flag: ComposerRootFlag

    var body: some View {
        if flag.isPresented {
            NewSessionView(viewModel, repositoryPresented: true, harnessPresented: false)
        } else {
            Color.clear
        }
    }
}

// MARK: - ModelPickerStatesHostedTests + Repository removal fixture

extension ModelPickerStatesHostedTests {

    func makeRemovableFixture(_ viewModel: some NewSessionViewModel, flag: ComposerRootFlag) -> Fixture {
        _ = NSApplication.shared
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let controller = NSHostingController(rootView: RemovableComposerRoot(viewModel: viewModel, flag: flag))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 1280, height: 800)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        return Fixture(window: window, host: host, previousActivationPolicy: previous)
    }
}

// MARK: - ModelPickerStatesHostedTests + H4 composer removal

extension ModelPickerStatesHostedTests {

    /// The binding setter's call during teardown cannot be observed without a production seam; a flush from it would
    /// deliver the final bytes, which shows as a write and is forbidden here. After the composer is gone, any popover
    /// still on screen is closed through real input and must still cause no write, commit or check.
    @Test(arguments: RepositoryComposerRemoval.allCases)
    func givenUndeliveredEditorBytes_whenTheComposerIsRemovedWithoutAClose_thenNothingIsDeliveredOrChecked(
        _ removal: RepositoryComposerRemoval
    ) async throws {
        // given
        let flag = ComposerRootFlag()
        let host = try await openFinalBytesHost(removableRoot: removal == .swiftUIRemoval ? flag : nil)
        defer { host.dispose() }
        let ended = countEndEditing(of: host.field)
        defer { NotificationCenter.default.removeObserver(ended) }
        let final = Self.finalBytes
        let outgoing = try #require(host.field.delegate, "The mounted coordinator must be the field's delegate.")
        host.editor.string = final
        let writesBefore = host.observed.repositoryWrites
        let checksBefore = host.useCase.directoryChecks

        // when
        switch removal {
        case .swiftUIRemoval:
            flag.isPresented = false
            // SwiftUI closes the popover and keeps the field mounted, so removal is keyed on the popover closing and
            // `disappear`, never on dismantle.
            await waitUntil(timeout: 8) { popovers(host).isEmpty && host.observed.events.contains("disappear") }
            try #require(popovers(host).isEmpty && host.observed.events.contains("disappear"),
                         Comment(rawValue: "The composer removal did not close the popover and disappear. \(removalState(host, outgoing))"))
        case .contentViewSwap:
            host.fixture.window.contentView = NSView(frame: NSRect(origin: .zero, size: host.fixture.window.frame.size))
            await waitUntil(timeout: 8) { popovers(host).isEmpty && host.observed.events.contains("disappear") }
            try #require(popovers(host).isEmpty && host.observed.events.contains("disappear"),
                         Comment(rawValue: "The content-view swap must close the popover and disappear. \(removalState(host, outgoing))"))
        }
        await DisplayFrames.waitForPresentedFrame()
        let removalReceipt = "removal=\(removal) \(removalState(host, outgoing))"
        #expect(host.observed.repositoryWrites == writesBefore, Comment(rawValue: removalReceipt))

        // when: an authenticated end-editing callback reaches the outgoing coordinator, mounted or not
        outgoing.controlTextDidEndEditing?(Notification(
            name: NSControl.textDidEndEditingNotification, object: host.field, userInfo: ["NSFieldEditor": host.editor]
        ))
        await Task.yield()
        await DisplayFrames.waitForPresentedFrame()

        // when: any popover left on screen is closed
        for popover in ownedPopovers(of: host.fixture.window) { try? sendFinalBytesEscape(to: popover) }
        await waitUntil(timeout: 2) { ownedPopovers(of: host.fixture.window).isEmpty }
        for popover in ownedPopovers(of: host.fixture.window) { popover.performClose(nil) }
        await waitUntil(timeout: 2) { ownedPopovers(of: host.fixture.window).isEmpty }
        await Task.yield()
        await DisplayFrames.waitForPresentedFrame()

        // then
        let receipt = Comment(rawValue: "\(removalReceipt) popoversAfterClose=\(ownedPopovers(of: host.fixture.window).count) "
            + "events=\(host.observed.events) endEditing=\(ended.count)")
        #expect(host.observed.repositoryWrites == writesBefore, receipt)
        #expect(!host.observed.events.contains { $0.hasPrefix("commit:") }, receipt)
        #expect(host.useCase.directoryChecks == checksBefore, receipt)
        #expect(host.useCase.directoryChecks.filter { $0 == [final] }.isEmpty, receipt)
        #expect(host.model.repo.utf8.elementsEqual(host.typedBytes.utf8), receipt)
        #expect(popovers(host).isEmpty, receipt)
    }

    private func popovers(_ host: FinalBytesHost) -> [NSWindow] { ownedPopovers(of: host.fixture.window) }

    private func removalState(_ host: FinalBytesHost, _ outgoing: any NSTextFieldDelegate) -> String {
        "popovers=\(popovers(host).count) popoversVisible=\(popovers(host).map(\.isVisible)) "
            + "dismantled=\(host.field.delegate == nil) delegateIsOutgoing=\(host.field.delegate === outgoing) "
            + "fieldWindowPresent=\(host.field.window != nil) disappeared=\(host.observed.events.contains("disappear")) "
            + "events=\(host.observed.events)"
    }
}
