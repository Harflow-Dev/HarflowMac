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

/// Establishes that real pointer input reaches each mounted repository target at its original point.
/// This is an activation baseline; it does not simulate validation settling during the held press.
extension ModelPickerStatesHostedTests {

    @Test(arguments: [true, false])
    func givenMountedRepositoryTargets_whenTheOriginalPointIsClicked_thenOnlyThatTargetActivates(useChooser: Bool) async throws {
        // given
        let scenario = makePointerBaselineScenario()
        defer { scenario.fixture.dispose(); withExtendedLifetime(scenario.routing) {} }

        try await activate(scenario.fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: scenario.fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: scenario.fixture.window).first)
        await waitUntil(timeout: 8) { popover.isKeyWindow && ownedPopovers(of: scenario.fixture.window).contains { $0 === popover } }
        try #require(popover.isKeyWindow && ownedPopovers(of: scenario.fixture.window).contains { $0 === popover })
        let field = try #require(tree(popover).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        try #require(popover.firstResponder === editor)
        let editPath = "/fixture/repos/pending-edit"
        editor.insertText(editPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { scenario.model.repo.utf8.elementsEqual(editPath.utf8) }
        let targetLabel = useChooser ? "Choose folder…" : "Recent repository HarflowEngine"
        await waitUntil(timeout: 8) { pointerBaselineFrame(label: targetLabel, in: popover) != nil }
        await DisplayFrames.waitForPresentedFrame()
        let originalFrame = try #require(pointerBaselineFrame(label: targetLabel, in: popover))
        let screenPoint = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let hitOriginalPoint = try pointerBaselineHit(screenPoint, in: popover)
        try #require(hitOriginalPoint)

        let otherLabel = useChooser ? "Recent repository HarflowEngine" : "Choose folder…"
        let otherFrame = try #require(pointerBaselineFrame(label: otherLabel, in: popover))
        let mouseEvents = try pointerBaselineMouseEvents(screenPoint, in: popover)
        let selectionGeneration = scenario.model.repoSelectionGeneration

        // when
        NSApp.postEvent(mouseEvents.down, atStart: false)
        NSApp.postEvent(mouseEvents.up, atStart: false)
        let queuedDown = try #require(NSApp.nextEvent(matching: [.leftMouseDown], until: Date().addingTimeInterval(1),
                                                      inMode: .default, dequeue: true))
        NSApp.sendEvent(queuedDown)
        if useChooser {
            await waitUntil(timeout: 5) { scenario.model.repo.utf8.elementsEqual(scenario.selectedPath.utf8) }
        } else {
            await waitUntil(timeout: 5) { scenario.model.repo.utf8.elementsEqual(scenario.recentPath.utf8) }
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        #expect(pointerBaselineFrame(label: targetLabel, in: popover) == originalFrame)
        #expect(pointerBaselineFrame(label: otherLabel, in: popover) == otherFrame)
        #expect(popover.isKeyWindow && ownedPopovers(of: scenario.fixture.window).contains { $0 === popover })
        #expect(scenario.model.repoSelectionGeneration == selectionGeneration + 1)
        if useChooser {
            #expect(scenario.routing.chooseDirectoryCalls == 1)
            #expect(scenario.model.repo.utf8.elementsEqual(scenario.selectedPath.utf8))
        } else {
            #expect(scenario.model.repo.utf8.elementsEqual(scenario.recentPath.utf8))
            #expect(scenario.routing.chooseDirectoryCalls == 0)
            #expect(!otherFrame.contains(screenPoint))
        }
    }

    private struct PointerBaselineScenario {
        let model: NewSessionVM
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
        return PointerBaselineScenario(model: model, routing: routing, fixture: fixture)
    }

    private func pointerBaselineHit(_ point: CGPoint, in window: NSWindow) throws -> Bool {
        let content = try #require(window.contentView)
        let windowPoint = window.convertPoint(fromScreen: point)
        let hit = try #require(content.hitTest(content.convert(windowPoint, from: nil)))
        return hit.window === window
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
