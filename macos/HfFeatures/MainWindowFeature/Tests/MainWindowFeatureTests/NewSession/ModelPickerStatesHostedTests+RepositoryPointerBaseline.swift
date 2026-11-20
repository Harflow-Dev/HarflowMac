//
//  ModelPickerStatesHostedTests+RepositoryPointerBaseline.swift
//  MainWindowFeatureTests
//

import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ModelPickerStatesHostedTests + Repository Pointer Baseline

/// Establishes that real pointer input reaches each mounted repository target at its original point, with the field
/// idle and while it holds an edit. Both events go through `NSApp.sendEvent` with real timestamps, the route a hosted
/// diagnostic showed to activate both targets in both states. It does not simulate validation settling during the
/// held press.
extension ModelPickerStatesHostedTests {

    struct PointerBaselineCase: Sendable, CustomTestStringConvertible {
        let useChooser: Bool
        let editing: Bool
        var testDescription: String { "\(useChooser ? "chooser" : "recent")-\(editing ? "editing" : "idle")" }
        static let all = [true, false].flatMap { target in [false, true].map { PointerBaselineCase(useChooser: target, editing: $0) } }
    }

    @Test(arguments: PointerBaselineCase.all)
    func givenMountedRepositoryTargets_whenTheOriginalPointIsClicked_thenOnlyThatTargetActivates(
        _ testCase: PointerBaselineCase
    ) async throws {
        // given
        let useChooser = testCase.useChooser
        let scenario = makePointerBaselineScenario()
        defer { scenario.fixture.dispose(); withExtendedLifetime(scenario.routing) {} }

        try await activate(scenario.fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: scenario.fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: scenario.fixture.window).first)
        await waitUntil(timeout: 8) { popover.isKeyWindow && ownedPopovers(of: scenario.fixture.window).contains { $0 === popover } }
        try #require(popover.isKeyWindow && ownedPopovers(of: scenario.fixture.window).contains { $0 === popover })
        let field = try #require(tree(popover).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let editPath = "/fixture/repos/pending-edit"
        if testCase.editing {
            try #require(popover.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            try #require(popover.firstResponder === editor)
            editor.insertText(editPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await waitUntil(timeout: 8) { scenario.model.repo.utf8.elementsEqual(editPath.utf8) }
        } else {
            try #require(popover.makeFirstResponder(nil))
            try #require(field.currentEditor() == nil)
        }
        let targetLabel = useChooser ? "Choose folder…" : "Recent repository HarflowEngine"
        await waitUntil(timeout: 8) { pointerBaselineFrame(label: targetLabel, in: popover) != nil }
        await DisplayFrames.waitForPresentedFrame()
        let originalFrame = try #require(pointerBaselineFrame(label: targetLabel, in: popover))
        let screenPoint = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let windowNumberAtPoint = try pointerBaselineRequireHit(screenPoint, in: popover)

        let otherLabel = useChooser ? "Recent repository HarflowEngine" : "Choose folder…"
        let otherFrame = try #require(pointerBaselineFrame(label: otherLabel, in: popover))
        let popoverOriginBefore = popover.frame.origin
        let selectionGeneration = scenario.model.repoSelectionGeneration

        // when
        try pointerBaselineClick(screenPoint, in: popover)
        let expectedPath = useChooser ? scenario.selectedPath : scenario.recentPath
        await waitUntil(timeout: 5) { scenario.model.repo.utf8.elementsEqual(expectedPath.utf8) }
        await waitUntil(timeout: 5) { scenario.model.repoCheckTask == nil }
        #expect(scenario.model.repo.utf8.elementsEqual(expectedPath.utf8), "The click must commit the repository in time.")
        #expect(scenario.model.repoCheckTask == nil, "The repository check must settle after the click.")
        await DisplayFrames.waitForPresentedFrame()

        // then
        let receipt = Comment(rawValue: "case=\(testCase.testDescription) windowNumberAtPoint=\(windowNumberAtPoint) "
            + "popoverWindowNumber=\(popover.windowNumber) repo=\(scenario.model.repo) "
            + "repoError=\(scenario.model.repoError ?? "nil") directoryChecks=\(scenario.useCase.directoryChecks) "
            + "editorDetached=\(field.currentEditor() == nil) chooseDirectoryCalls=\(scenario.routing.chooseDirectoryCalls)")
        pointerBaselineExpectCommit(scenario, popover: popover, expectedPath: expectedPath,
                                    selectionGeneration: selectionGeneration, receipt)
        // The selection can change the pill's width and re-anchor the popover, so geometry is judged inside the popover.
        let framesReceipt = pointerBaselineFramesReceipt(receipt, popover: popover, originBefore: popoverOriginBefore,
                                                         frames: [(targetLabel, originalFrame), (otherLabel, otherFrame)])
        for (label, before) in [(targetLabel, originalFrame), (otherLabel, otherFrame)] {
            let after = try #require(pointerBaselineFrame(label: label, in: popover), framesReceipt)
            #expect(after.offsetBy(dx: -popover.frame.origin.x, dy: -popover.frame.origin.y)
                == before.offsetBy(dx: -popoverOriginBefore.x, dy: -popoverOriginBefore.y), framesReceipt)
        }
        if testCase.editing {
            #expect(!scenario.useCase.directoryChecks.contains { $0 == [editPath] },
                    "The click must not trigger a stale-edit check of the pending bytes. \(receipt)")
        }
        if useChooser {
            #expect(scenario.routing.chooseDirectoryCalls == 1, receipt)
        } else {
            #expect(scenario.routing.chooseDirectoryCalls == 0, receipt)
            #expect(!otherFrame.contains(screenPoint), receipt)
        }
    }

    private func pointerBaselineExpectCommit(
        _ scenario: PointerBaselineScenario, popover: NSWindow, expectedPath: String, selectionGeneration: Int, _ receipt: Comment
    ) {
        #expect(scenario.model.repo.utf8.elementsEqual(expectedPath.utf8), receipt)
        #expect(scenario.model.repoSelectionGeneration == selectionGeneration + 1, receipt)
        #expect(scenario.model.repoError == nil, receipt)
        #expect(popover.isKeyWindow && ownedPopovers(of: scenario.fixture.window).contains { $0 === popover }, receipt)
    }

    private func pointerBaselineFramesReceipt(
        _ receipt: Comment, popover: NSWindow, originBefore: CGPoint, frames: [(label: String, before: NSRect)]
    ) -> Comment {
        let moved = frames.map { "\($0.label) before=\($0.before) after=\(String(describing: pointerBaselineFrame(label: $0.label, in: popover)))" }
        return Comment(rawValue: "\(receipt) popoverOriginBefore=\(originBefore) popoverOriginAfter=\(popover.frame.origin) "
            + moved.joined(separator: " "))
    }

    private struct PointerBaselineScenario {
        let model: NewSessionVM
        let useCase: HostedListingUseCase
        let routing: PointerBaselineRouting
        let fixture: Fixture
        let recentPath = "/fixture/repos/HarflowEngine"
        let selectedPath = "/fixture/repos/chooser-selection"
    }

    private func makePointerBaselineScenario() -> PointerBaselineScenario {
        let recentPath = "/fixture/repos/HarflowEngine"
        let task = TaskInfo(.object([
            "task_id": .string("recent"), "backend": .string("claude"), "status": .string("completed"),
            "repo_path": .string(recentPath), "started_at": .string("2026-09-30T10:50:00Z")
        ]))!
        let catalog = BackendCatalog(entries: [BackendControlFixtures.entry("claude", installed: true)], state: .available)
        let useCase = HostedListingUseCase(catalog: catalog, listings: [:], taskList: [task])
        let routing = PointerBaselineRouting()
        let model = NewSessionVM(useCase: useCase, routing: routing)
        model.didTapRecentRepo("/fixture/repos/initial")
        model.didChangeMessage("Inspect the repository")
        let fixture = makeFixture(model, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        return PointerBaselineScenario(model: model, useCase: useCase, routing: routing, fixture: fixture)
    }

    /// Hit-tests through the popover's frame view, the way AppKit routes a click, and requires the point to land in the
    /// hosting view. The window number AppKit reports at that point is returned for the receipt only: a hosted run showed
    /// it can name another window while activation still reached the popover.
    private func pointerBaselineRequireHit(_ point: CGPoint, in popover: NSWindow) throws -> Int {
        let content = try #require(popover.contentView)
        let frameView = try #require(content.superview)
        let windowPoint = popover.convertPoint(fromScreen: point)
        let hit = try #require(frameView.hitTest(windowPoint), "No view at the click point.")
        #expect(String(describing: type(of: content)).contains("HostingView"), "The popover content must be the hosting view.")
        #expect(hit.isDescendant(of: content), "The hit \(type(of: hit)) must be inside the hosting view.")
        return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
    }

    /// Both events go through `NSApp.sendEvent` with real timestamps, as a hardware click would arrive.
    private func pointerBaselineClick(_ point: CGPoint, in window: NSWindow) throws {
        let windowPoint = window.convertPoint(fromScreen: point)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
    }

    func pointerBaselineMouseEvents(_ point: CGPoint, in window: NSWindow) throws -> (down: NSEvent, up: NSEvent) {
        let windowPoint = window.convertPoint(fromScreen: point)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        return (down, up)
    }

    private func pointerBaselineElement(label: String, in window: NSWindow) -> NSObject? {
        let matches = pointerBaselineTree(window).filter { pointerBaselineString($0, key: "accessibilityLabel") == label }
        return matches.count == 1 ? matches.first : nil
    }

    func pointerBaselineFrame(label: String, in window: NSWindow) -> NSRect? {
        guard let element = pointerBaselineElement(label: label, in: window) else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = element.value(forKey: "accessibilityFrame") as? NSValue
        else { return nil }
        return value.rectValue
    }

    func pointerBaselineTree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ node: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let selector = NSSelectorFromString("accessibilityChildren")
            let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] : nil
            let accessibleChildren = NSAccessibility.unignoredChildren(from: children ?? []).compactMap { $0 as? NSObject }
            return [node] + accessibleChildren.flatMap(collect)
        }
        return collect(root)
    }

    func pointerBaselineString(_ object: NSObject, key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

}

@MainActor
private final class PointerBaselineRouting: NewSessionRouting {
    let selectedPath = "/fixture/repos/chooser-selection"
    private(set) var chooseDirectoryCalls = 0

    func chooseDirectory() async -> String? {
        chooseDirectoryCalls += 1
        return selectedPath
    }

    func didStart(taskID: String) {}
    func dismiss() {}
    func reviewRecent() {}
}
