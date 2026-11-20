//
//  ModelPickerStatesHostedTests+Repository.swift
//  MainWindowFeatureTests
//

import AppKit
import Foundation
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - ModelPickerStatesHostedTests + Repository

/// Hosted evidence for the repository popover's "Recent" chips: one line each, bounded width, wrapping as whole
/// chips, and only existing folders. An extension of the registered hosted suite, so it shares its identity.
extension ModelPickerStatesHostedTests {

    private static let worktreePrefix = "harflow-mac-repository-picker-validation-and-recent-chips-review-"
    private static let presentNames = [
        "HarflowEngine", worktreePrefix + "e2f0c3", worktreePrefix + "9b41d7", "HarflowDesign", "HarflowMCP"
    ]
    private static let missingName = "DeletedRepositoryFolder"

    private static func repoTask(_ id: String, path: String, minute: Int) -> TaskInfo {
        let raw: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
            "repo_path": .string(path), "started_at": .string(String(format: "2026-09-30T10:%02d:00Z", minute))
        ]
        return TaskInfo(.object(raw))!
    }

    private func makeRecentsViewModel() -> NewSessionVM {
        // The missing folder is the newest task, so the existence filter has to drop it rather than the limit.
        var tasks = [Self.repoTask("t0", path: "/fixture/repos/\(Self.missingName)", minute: 59)]
        for (index, name) in Self.presentNames.enumerated() {
            tasks.append(Self.repoTask("t\(index + 1)", path: "/fixture/repos/\(name)", minute: 50 - index))
        }
        let catalog = BackendCatalog(entries: [BackendControlFixtures.entry("claude", installed: true)], state: .available)
        let useCase = HostedListingUseCase(
            catalog: catalog, listings: [:], taskList: tasks, missingPaths: ["/fixture/repos/\(Self.missingName)"]
        )
        let sut = NewSessionVM(useCase: useCase, routing: MockNewSessionRouting())
        sut.didChangeBackend("claude")
        sut.didTapRecentRepo("/fixture/repos/HarflowMCP")
        return sut
    }

    /// The screen-coordinate frame of the first element labelled `label` that has a non-empty frame.
    private func frame(ofLabel label: String, in window: NSWindow) -> NSRect? {
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        for object in tree(window) where object.responds(to: labelSelector) {
            guard object.perform(labelSelector)?.takeUnretainedValue() as? String == label else { continue }
            if let frame = accessibilityFrame(of: object), !frame.isEmpty { return frame }
        }
        return nil
    }

    /// SwiftUI's accessibility nodes can fail protocol casts, so fall back to reading the property by selector.
    private func accessibilityFrame(of object: NSObject) -> NSRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue
        else { return nil }
        return value.rectValue
    }

    @Test
    func givenLongRecentRepositories_whenTheRepositoryPopoverIsHosted_thenEveryChipStaysOnOneLineInsideThePopover() async throws {
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
            for dark in [false, true] {
                // given
                let fixture = makeFixture(makeRecentsViewModel(), size: size, dark: dark, harnessPresented: false, repositoryPresented: true)
                defer { fixture.dispose() }
                let label = "repository-recents-\(Int(size.width))-\(dark ? "dark" : "light")"

                // when
                try await activate(fixture.window)
                await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
                let popover = try #require(ownedPopovers(of: fixture.window).first, "The repository popover must open through the seam.")
                // The existence check is asynchronous: wait for every present chip to be laid out.
                await waitUntil(timeout: 8) {
                    Self.presentNames.allSatisfy { frame(ofLabel: "Recent repository \($0)", in: popover) != nil }
                }
                await DisplayFrames.waitForPresentedFrame()
                try capture(try #require(popover.contentView), name: label + "-popover")

                // then
                let content = try #require(popover.contentView)
                let bounds = popover.convertToScreen(content.convert(content.bounds, to: nil)).insetBy(dx: -1, dy: -1)
                let frames = Self.presentNames.compactMap { name in frame(ofLabel: "Recent repository \(name)", in: popover).map { (name, $0) } }
                #expect(frames.count == Self.presentNames.count, "Every existing repository has a chip (\(label)).")
                let oneLine = try #require(frames.map(\.1.height).min())
                for (name, rect) in frames {
                    #expect(rect.height <= oneLine + 1, "\(name) must not wrap (\(label)): height \(rect.height) vs \(oneLine)")
                    #expect(
                        rect.width <= 329,
                        "\(name) must stay within the chip maximum (\(label)): \(rect.width)"
                    )
                    #expect(bounds.contains(rect), "\(name) must lie inside the popover (\(label)): \(rect) vs \(bounds)")
                }
                for name in Self.presentNames where name.hasPrefix(Self.worktreePrefix) {
                    let frame = try #require(frames.first { $0.0 == name }?.1)
                    #expect(frame.width > 256, "The chip uses more than the old width: \(name), \(frame.width)")
                    let chip = try #require(element(label: "Recent repository \(name)", in: popover))
                    #expect(accessibilityString(chip, property: "accessibilityHelp") == "/fixture/repos/\(name)")
                }
                let rows = Set(frames.map { Int($0.1.minY.rounded()) })
                #expect(rows.count > 1, "The chips must wrap as whole chips onto more than one row (\(label)).")
                #expect(
                    frame(ofLabel: "Recent repository \(Self.missingName)", in: popover) == nil,
                    "A deleted folder must not appear as a chip (\(label))."
                )
            }
        }
    }

    @Test
    func givenNoRecentFolders_whenTheRepositoryPopoverOpens_thenTheEmptyFieldIsNeutral() async throws {
        // given
        let (model, _, routing) = makeRepositoryModel(repo: "")
        defer { withExtendedLifetime(routing) {} }
        let fixture = makeFixture(model, size: NSSize(width: 1000, height: 620), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        defer { fixture.dispose() }

        // when
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        await DisplayFrames.waitForPresentedFrame()

        // then
        #expect(element(label: "Repository path", in: popover) != nil)
        #expect(frame(ofLabel: "Recent", in: popover) == nil)
        #expect(element(identifier: "repository-path-error", in: popover) == nil)
        #expect(element(identifier: "composer-repository-empty", in: fixture.window) != nil)
        #expect(!model.canStart && model.repoError == nil)
    }

    @Test
    func givenATypedMissingFolder_whenReturnCommits_thenTheFieldShowsAnAccessibleErrorWithoutStarting() async throws {
        // given
        let (model, useCase, routing) = makeRepositoryModel(repo: "/fixture/repos/initial")
        defer { withExtendedLifetime(routing) {} }
        let fixture = makeFixture(model, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        await waitUntil(timeout: 8) { repositoryNativeField(in: popover) != nil }
        let field = try #require(repositoryNativeField(in: popover))
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let invalidPath = "/fixture/repos/\(Self.missingName)"
        editor.insertText(invalidPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo == invalidPath && model.canStart }
        try #require(model.repo == invalidPath && model.canStart, "The composer can start before the field commit")
        #expect(useCase.directoryChecks.isEmpty && model.repoError == nil)

        // when
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: popover.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        popover.sendEvent(event)
        let error = "Choose an existing folder."
        await waitUntil(timeout: 8) { model.repoError == error }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let note = try #require(element(identifier: "repository-path-error", in: popover))
        let path = try #require(repositoryProbeAXFields(in: popover).first {
            accessibilityString($0, property: "accessibilityValue") == invalidPath
        }, "The field must be exposed as the repository AX text field.")
        #expect(accessibilityString(path, property: "accessibilityHelp") == error)
        let noteFrame = try #require(accessibilityFrame(of: note))
        let fieldFrame = try #require(accessibilityFrame(of: path))
        #expect(noteFrame.midY < fieldFrame.midY)
        #expect(element(identifier: "composer-repository-error", in: fixture.window) != nil)
        #expect(!model.canStart && useCase.directoryChecks == [[invalidPath]])
        #expect(useCase.startProbes.isEmpty && useCase.launchedRequests.isEmpty)

        try #require(popover.makeFirstResponder(field))
        let corrected = try #require(field.currentEditor() as? NSTextView)
        let validPath = "/fixture/repos/valid"
        corrected.insertText(validPath, replacementRange: NSRange(location: 0, length: corrected.string.utf16.count))
        await waitUntil(timeout: 8) {
            model.repo.utf8.elementsEqual(validPath.utf8) && model.hasUncommittedRepoEdit
                && model.repoError == nil && model.canStart && useCase.directoryChecks == [[invalidPath]]
        }
        #expect(model.repoError == nil && model.canStart)
        #expect(useCase.directoryChecks == [[invalidPath]], "Editing clears the mark before the next commit")
        try #require(popover.makeFirstResponder(nil))
        await waitUntil(timeout: 8) {
            useCase.directoryChecks == [[invalidPath], [validPath]] && !model.hasUncommittedRepoEdit
                && model.repoCheckTask == nil && model.repo.utf8.elementsEqual(validPath.utf8)
                && model.repoError == nil && model.canStart
        }
        try #require(useCase.directoryChecks == [[invalidPath], [validPath]], "The corrected path must be checked exactly once.")
        #expect(!model.hasUncommittedRepoEdit && model.repoCheckTask == nil)
        #expect(model.repo.utf8.elementsEqual(validPath.utf8) && model.repoError == nil && model.canStart)
        #expect(useCase.startProbes.isEmpty && useCase.launchedRequests.isEmpty)
    }

    @Test(.enabled("Requires macOS Keyboard navigation") { await MainActor.run { NSApp.isFullKeyboardAccessEnabled } })
    func givenATypedMissingFolder_whenTabMovesToChooseFolder_thenTheEditCommitsInTheSamePopover() async throws {
        // given
        let (model, useCase, routing) = makeRepositoryModel(repo: "/fixture/repos/initial")
        defer { withExtendedLifetime(routing) {} }
        let fixture = makeFixture(model, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        #expect(NSApp.isFullKeyboardAccessEnabled, "The physical Tab case runs only with Keyboard navigation enabled.")
        let chooser = try #require(repositoryProbeButton(label: "Choose folder…", in: popover),
                                   "The destination must be the mounted production chooser AX button.")
        let field = try #require(repositoryNativeField(in: popover))
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let invalidPath = "/fixture/repos/\(Self.missingName)"
        editor.insertText(invalidPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo.utf8.elementsEqual(invalidPath.utf8) }
        #expect(useCase.directoryChecks.isEmpty && model.repoError == nil)

        // when
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: popover.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        popover.sendEvent(tab)
        await waitUntil(timeout: 8) { useCase.directoryChecks == [[invalidPath]] }
        await waitUntil(timeout: 8) { model.repoError == NewSessionVM.missingRepoMessage }

        // then
        #expect(popover.isVisible && popover.isKeyWindow && ownedPopovers(of: fixture.window).contains(popover))
        let focusedChooser = repositoryProbeFocusedElement(in: popover)
        #expect(focusedChooser === chooser || repositoryProbeMatches(focusedChooser, chooser),
                "Tab should land on the exact production chooser AX control.")
        #expect(field.currentEditor() == nil, "The outgoing field editor should detach after Tab.")
        #expect(useCase.directoryChecks == [[invalidPath]], "One Tab departure produces one check.")
        #expect(model.repo.utf8.elementsEqual(invalidPath.utf8) && !model.canStart)
        #expect(element(identifier: "repository-path-error", in: popover) != nil)
        #expect(element(identifier: "composer-repository-error", in: fixture.window) != nil)
        let exposedField = try #require(repositoryProbeAXFields(in: popover).first {
            accessibilityString($0, property: "accessibilityValue") == invalidPath
        })
        #expect(accessibilityString(exposedField, property: "accessibilityHelp") == NewSessionVM.missingRepoMessage)
        #expect(useCase.startProbes.isEmpty && useCase.launchedRequests.isEmpty)
    }

    @Test
    func givenATypedMissingFolder_whenFocusMovesToAnInertNativeControl_thenTheEditCommitsOnce() async throws {
        // given
        let (model, useCase, routing) = makeRepositoryModel(repo: "/fixture/repos/initial")
        defer { withExtendedLifetime(routing) {} }
        let fixture = makeFixture(model, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        let recentChecks = useCase.directoryChecks
        let field = try #require(repositoryNativeField(in: popover))
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let invalidPath = "/fixture/repos/\(Self.missingName)"
        editor.insertText(invalidPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo.utf8.elementsEqual(invalidPath.utf8) }
        let inert = try installRepositoryFocusSentinel(awayFrom: field, in: popover)
        let editingEndObserver = RepositoryEditingEndObserver()
        let notifications = NotificationCenter.default
        notifications.addObserver(editingEndObserver, selector: #selector(RepositoryEditingEndObserver.didEndEditing(_:)),
                                  name: NSControl.textDidEndEditingNotification, object: field)
        defer {
            notifications.removeObserver(editingEndObserver, name: NSControl.textDidEndEditingNotification, object: field)
            inert.removeFromSuperview()
        }
        try #require(popover.isKeyWindow && ownedPopovers(of: fixture.window).contains { $0 === popover })
        try #require(popover.firstResponder === editor && field.currentEditor() === editor)
        #expect(useCase.directoryChecks == recentChecks && model.repoError == nil)

        // when
        try #require(popover.makeFirstResponder(inert))
        await waitUntil(timeout: 8) { useCase.directoryChecks == [[invalidPath]] }
        await waitUntil(timeout: 8) { model.repoError == NewSessionVM.missingRepoMessage }

        // then
        #expect(popover.firstResponder === inert)
        #expect(popover.isVisible && popover.isKeyWindow && ownedPopovers(of: fixture.window).contains(popover))
        #expect(field.currentEditor() == nil)
        #expect(editingEndObserver.count == 1, "The exact mounted field emits one native editing-end event.")
        #expect(
            useCase.directoryChecks == recentChecks + [[invalidPath]],
            "A real departure to an unrelated native responder commits once regardless of keyboard settings."
        )
        #expect(model.repo.utf8.elementsEqual(invalidPath.utf8) && !model.canStart)
        #expect(element(identifier: "repository-path-error", in: popover) != nil)
        #expect(element(identifier: "composer-repository-error", in: fixture.window) != nil)
        #expect(useCase.startProbes.isEmpty && useCase.launchedRequests.isEmpty)
    }

    private final class RepositoryFocusSentinel: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }

    func installRepositoryFocusSentinel(awayFrom field: NSTextField, in popover: NSWindow) throws -> NSButton {
        let content = try #require(popover.contentView)
        try #require(field.window === popover)
        let fieldFrame = field.convert(field.bounds, to: content)
        let bounds = content.bounds
        let sentinelSize = NSSize(width: 144, height: 26)
        let inset: CGFloat = 8
        let candidates = [
            NSRect(x: bounds.maxX - sentinelSize.width - inset, y: bounds.minY + inset,
                   width: sentinelSize.width, height: sentinelSize.height),
            NSRect(x: bounds.maxX - sentinelSize.width - inset, y: bounds.maxY - sentinelSize.height - inset,
                   width: sentinelSize.width, height: sentinelSize.height)
        ]
        let frame = try #require(candidates.first { bounds.contains($0) && !$0.intersects(fieldFrame) })
        let sentinel = RepositoryFocusSentinel(frame: frame)
        sentinel.title = "Hosted inert focus target"
        sentinel.setAccessibilityIdentifier("repository-focus-departure-sentinel")
        content.addSubview(sentinel, positioned: .above, relativeTo: nil)
        let eligible = sentinel.window === popover && sentinel.acceptsFirstResponder && !sentinel.visibleRect.isEmpty
        if !eligible { sentinel.removeFromSuperview() }
        try #require(eligible)
        return sentinel
    }

    private final class RepositoryEditingEndObserver: NSObject {
        var count = 0

        @objc func didEndEditing(_ notification: Notification) { count += 1 }
    }

    /// Returns exposed accessibility children only, excluding raw backing views.
    private func repositoryProbeAXTree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ node: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let selector = NSSelectorFromString("accessibilityChildren")
            let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] : nil
            let unignored = NSAccessibility.unignoredChildren(from: children ?? []).compactMap { $0 as? NSObject }
            return [node] + unignored.flatMap(collect)
        }
        return collect(root)
    }

    private func repositoryProbeAXFields(in window: NSWindow) -> [NSObject] {
        repositoryProbeAXTree(window).filter {
            accessibilityString($0, property: "accessibilityRole") == "AXTextField"
                && accessibilityString($0, property: "accessibilityLabel") == "Repository path"
        }
    }

    func repositoryNativeField(in window: NSWindow) -> NSTextField? {
        let candidates = tree(window).compactMap { $0 as? NSTextField }.filter { field in
            field.isEditable && field.window === window
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func repositoryProbeMatches(_ first: NSObject?, _ second: NSObject) -> Bool {
        guard let first else { return false }
        return accessibilityString(first, property: "accessibilityRole") == "AXButton"
            && accessibilityString(first, property: "accessibilityLabel") == accessibilityString(second, property: "accessibilityLabel")
            && accessibilityFrame(of: first) == accessibilityFrame(of: second)
    }

    private func repositoryProbeButton(label: String, in window: NSWindow) -> NSObject? {
        let candidates = repositoryProbeAXTree(window).filter { object in
            guard accessibilityString(object, property: "accessibilityRole") == "AXButton",
                  accessibilityString(object, property: "accessibilityLabel") == label ||
                  accessibilityString(object, property: "accessibilityTitle") == label,
                  let frame = accessibilityFrame(of: object), !frame.isEmpty
            else { return false }
            return window.frame.contains(frame)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func repositoryProbeFocusedElement(in window: NSWindow) -> NSObject? {
        for root in [window as NSObject, NSApplication.shared] {
            let selector = NSSelectorFromString("accessibilityFocusedUIElement")
            if root.responds(to: selector), let element = root.perform(selector)?.takeUnretainedValue() as? NSObject {
                return element
            }
        }
        return nil
    }

    private func repositoryProbePress(_ object: NSObject) throws {
        if let accessible = object as? any NSAccessibilityProtocol {
            try #require(accessible.accessibilityPerformPress(), "The production control rejected its AX press action.")
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try #require(object.responds(to: selector), "The production control must expose its AX press action.")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Press.self)
        try #require(implementation(object, selector), "The production control rejected its AX press action.")
    }

    @Test(arguments: RepositorySelectionCase.allCases)
    func givenAnActiveRepositoryEditor_whenChooserOrRecentSelectionReplacesItsValue_thenTheSameEditorAcceptsExactNewBytes(
        _ scenario: RepositorySelectionCase
    ) async throws {
        let hosted = try await makeRepositorySelectionFixture(useChooser: scenario.useChooser)
        defer { hosted.fixture.dispose(); withExtendedLifetime(hosted.routing) {} }
        let oldPath = "/fixture/repos/old-edit"
        let selectedPath = scenario.useChooser ? "/fixture/repos/chooser-selection" : "/fixture/repos/HarflowEngine"

        try await selectRepositoryWithoutRefocus(hosted, useChooser: scenario.useChooser, selectedPath: selectedPath)
        #expect(hosted.observed.repositoryWrites.count == 1, "Selection must invalidate every queued write from the previous field edit.")
        try await continueEditingRepositoryWithoutRefocus(hosted, selectedPath: selectedPath, commitWithReturn: scenario.commitWithReturn)
        #expect(hosted.observed.repositoryWrites.map { Array($0.utf8) } == [
            Array(oldPath.utf8), Array("/fixture/repos/cafe\u{301}".utf8)
        ])
    }

    enum RepositorySelectionCase: CaseIterable, Sendable, CustomTestStringConvertible {
        case chooserReturn, chooserBlur, recentReturn, recentBlur

        var useChooser: Bool { self == .chooserReturn || self == .chooserBlur }
        var commitWithReturn: Bool { self == .chooserReturn || self == .recentReturn }
        var testDescription: String {
            switch self {
            case .chooserReturn: "chooser-return"
            case .chooserBlur: "chooser-blur"
            case .recentReturn: "recent-return"
            case .recentBlur: "recent-blur"
            }
        }
    }

    private struct RepositorySelectionFixture {
        let model: NewSessionVM
        let useCase: HostedListingUseCase
        let routing: MockNewSessionRouting
        let observed: RepositoryBindingObservedViewModel
        let fixture: Fixture
        let popover: NSWindow
        let field: NSTextField
        let editor: NSTextView
        let recentChecks: [[String]]
    }

    private func makeRepositorySelectionFixture(useChooser: Bool) async throws -> RepositorySelectionFixture {
        let selectedPath = useChooser ? "/fixture/repos/chooser-selection" : "/fixture/repos/HarflowEngine"
        let catalog = BackendCatalog(entries: [BackendControlFixtures.entry("claude", installed: true)], state: .available)
        let tasks = [Self.repoTask("recent", path: "/fixture/repos/HarflowEngine", minute: 50)]
        let useCase = HostedListingUseCase(catalog: catalog, listings: [:], taskList: tasks)
        let routing = MockNewSessionRouting()
        given(routing).didStart(taskID: .any).willReturn()
        given(routing).chooseDirectory().willReturn(selectedPath)
        let model = NewSessionVM(useCase: useCase, routing: routing)
        model.didTapRecentRepo("/fixture/repos/initial")
        model.didChangeMessage("Inspect the repository")
        let observed = RepositoryBindingObservedViewModel(model)
        let fixture = makeFixture(observed, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        var transferred = false
        defer { if !transferred { fixture.dispose() } }
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        await waitUntil(timeout: 8) { model.recentRepos.contains { $0.id == "/fixture/repos/HarflowEngine" } }
        let recentChecks = useCase.directoryChecks
        let field = try #require(repositoryNativeField(in: popover))
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let oldPath = "/fixture/repos/old-edit"
        editor.insertText(oldPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo.utf8.elementsEqual(oldPath.utf8) }
        try #require(useCase.directoryChecks == recentChecks && model.repoError == nil)
        try #require(popover.firstResponder === editor)
        try #require(observed.repositoryWrites.count == 1 && observed.repositoryWrites[0].utf8.elementsEqual(oldPath.utf8))
        transferred = true
        return RepositorySelectionFixture(model: model, useCase: useCase, routing: routing, observed: observed,
                                          fixture: fixture, popover: popover, field: field, editor: editor,
                                          recentChecks: recentChecks)
    }

    private func selectRepositoryWithoutRefocus(
        _ hosted: RepositorySelectionFixture, useChooser: Bool, selectedPath: String
    ) async throws {
        let label = useChooser ? "Choose folder…" : "Recent repository HarflowEngine"
        let button = try #require(repositoryProbeButton(label: label, in: hosted.popover))
        try repositoryProbePress(button)
        await waitUntil(timeout: 8) {
            hosted.model.repo.utf8.elementsEqual(selectedPath.utf8)
                && hosted.editor.string.utf8.elementsEqual(selectedPath.utf8)
        }
        try #require(hosted.field.currentEditor() === hosted.editor && hosted.popover.firstResponder === hosted.editor,
                     "Selection must retain the same active editor without a refocus action.")
        #expect(hosted.model.repo.utf8.elementsEqual(selectedPath.utf8))
        #expect(hosted.editor.string.utf8.elementsEqual(selectedPath.utf8), "The rendered editor must show exact selection bytes.")
        #expect(hosted.useCase.directoryChecks == hosted.recentChecks, "Selection must not commit a superseded edit.")
        #expect(hosted.observed.repositoryWrites.count == 1)
        if useChooser { await verify(hosted.routing).chooseDirectory().calledEventually(1, before: .seconds(5)) }
    }

    private func continueEditingRepositoryWithoutRefocus(
        _ hosted: RepositorySelectionFixture, selectedPath: String, commitWithReturn: Bool
    ) async throws {
        #expect(hosted.popover.isVisible && hosted.popover.isKeyWindow)
        #expect(hosted.model.repo.utf8.elementsEqual(selectedPath.utf8))
        let replacementPath = "/fixture/repos/cafe\u{301}"
        hosted.editor.insertText(replacementPath, replacementRange: NSRange(location: 0, length: hosted.editor.string.utf16.count))
        await waitUntil(timeout: 8) {
            hosted.model.repo.utf8.elementsEqual(replacementPath.utf8)
                && hosted.editor.string.utf8.elementsEqual(replacementPath.utf8)
        }
        #expect(hosted.model.repo.utf8.elementsEqual(replacementPath.utf8))
        #expect(hosted.editor.string.utf8.elementsEqual(replacementPath.utf8))
        #expect(hosted.model.hasUncommittedRepoEdit)
        #expect(hosted.observed.repositoryWrites.map { Array($0.utf8) } == [
            Array("/fixture/repos/old-edit".utf8), Array(replacementPath.utf8)
        ])
        #expect(hosted.useCase.directoryChecks == hosted.recentChecks)
        var focusTarget: NSButton?
        let editingEndObserver = RepositoryEditingEndObserver()
        let notifications = NotificationCenter.default
        notifications.addObserver(editingEndObserver, selector: #selector(RepositoryEditingEndObserver.didEndEditing(_:)),
                                  name: NSControl.textDidEndEditingNotification, object: hosted.field)
        defer {
            notifications.removeObserver(editingEndObserver, name: NSControl.textDidEndEditingNotification, object: hosted.field)
            focusTarget?.removeFromSuperview()
        }
        if commitWithReturn {
            try sendRepositoryProbeKey("\r", code: 36, to: hosted.popover)
        } else {
            let sentinel = try installRepositoryFocusSentinel(awayFrom: hosted.field, in: hosted.popover)
            focusTarget = sentinel
            try #require(hosted.popover.isVisible && hosted.popover.isKeyWindow
                && ownedPopovers(of: hosted.fixture.window).contains { $0 === hosted.popover })
            let endingCountBeforeTransfer = editingEndObserver.count
            try #require(hosted.popover.firstResponder === hosted.editor
                && hosted.field.currentEditor() === hosted.editor && hosted.model.hasUncommittedRepoEdit
                && hosted.model.repo.utf8.elementsEqual(replacementPath.utf8)
                && hosted.useCase.directoryChecks == hosted.recentChecks && endingCountBeforeTransfer == 0,
                "Blur source must be the authenticated active editor with this exact edit still pending.")
            try #require(hosted.popover.makeFirstResponder(sentinel))
            await waitUntil(timeout: 5) {
                hosted.popover.firstResponder === sentinel && hosted.field.currentEditor() == nil
                    && editingEndObserver.count == 1
            }
            try #require(hosted.popover.firstResponder === sentinel && hosted.field.currentEditor() == nil,
                         "Blur target must be the mounted inert sentinel and the previous field editor must detach.")
            try #require(editingEndObserver.count == 1, "The exact mounted field must emit one editing-end notification.")
        }
        await waitUntil(timeout: 8) {
            hosted.useCase.directoryChecks.count == hosted.recentChecks.count + 1
                && hosted.model.repo.utf8.elementsEqual(replacementPath.utf8)
                && hosted.model.repoCheckTask == nil && !hosted.model.hasUncommittedRepoEdit
                && hosted.model.repoError == nil && hosted.model.canStart
        }
        #expect(hosted.useCase.directoryChecks.count == hosted.recentChecks.count + 1)
        #expect(hosted.useCase.directoryChecks.last == [replacementPath] && hosted.model.canStart && hosted.model.repoError == nil)
    }

    func makeRepositoryModel(repo: String, refusesStart: Bool = false) -> (NewSessionVM, HostedListingUseCase, MockNewSessionRouting) {
        let catalog = BackendCatalog(entries: [BackendControlFixtures.entry("claude", installed: true)], state: .available)
        let useCase = HostedListingUseCase(catalog: catalog, listings: [:], missingPaths: ["/fixture/repos/\(Self.missingName)"],
                                           refusesStart: refusesStart)
        let routing = MockNewSessionRouting()
        given(routing).didStart(taskID: .any).willReturn()
        let model = NewSessionVM(useCase: useCase, routing: routing)
        model.didTapRecentRepo(repo)
        model.didChangeMessage("Inspect the repository")
        return (model, useCase, routing)
    }

    private func element(label: String, in window: NSWindow) -> NSObject? {
        tree(window).first { accessibilityString($0, property: "accessibilityLabel") == label }
    }

    private func element(identifier: String, in window: NSWindow) -> NSObject? {
        tree(window).first { accessibilityString($0, property: "accessibilityIdentifier") == identifier }
    }

    private func accessibilityString(_ object: NSObject, property: String) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}
