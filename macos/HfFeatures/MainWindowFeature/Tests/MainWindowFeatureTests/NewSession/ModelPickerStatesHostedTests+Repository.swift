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

    @Test(arguments: [true, false])
    func givenATypedMissingFolder_whenReturnOrFocusDepartureCommits_thenTheFieldShowsAnAccessibleErrorWithoutStarting(useReturn: Bool) async throws {
        // given
        let (model, useCase, routing) = makeRepositoryModel(repo: "/fixture/repos/initial")
        defer { withExtendedLifetime(routing) {} }
        let fixture = makeFixture(model, size: NSSize(width: 1280, height: 800), dark: !useReturn,
                                  harnessPresented: false, repositoryPresented: true)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        await waitUntil(timeout: 8) {
            tree(popover).contains { ($0 as? NSTextField)?.isEditable == true }
        }
        let editableField = tree(popover).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        let field = try #require(editableField)
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let invalidPath = "/fixture/repos/\(Self.missingName)"
        editor.insertText(invalidPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo == invalidPath && model.canStart }
        try #require(model.repo == invalidPath && model.canStart, "The composer can start before the field commit")
        #expect(useCase.directoryChecks.isEmpty && model.repoError == nil)

        // when
        if useReturn {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: popover.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            popover.sendEvent(event)
        } else {
            try #require(popover.makeFirstResponder(nil))
        }
        let error = "Choose an existing folder."
        await waitUntil(timeout: 8) { model.repoError == error }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let note = try #require(element(identifier: "repository-path-error", in: popover))
        let path = try #require(element(label: "Repository path", in: popover))
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
        await waitUntil(timeout: 8) { model.repo == validPath && model.canStart }
        #expect(model.repoError == nil && model.canStart)
        #expect(useCase.directoryChecks == [[invalidPath]], "Editing clears the mark before the next commit")
        try #require(popover.makeFirstResponder(nil))
        await waitUntil(timeout: 8) { useCase.directoryChecks == [[invalidPath], [validPath]] }
        #expect(model.repoError == nil && model.canStart)
        #expect(useCase.startProbes.isEmpty && useCase.launchedRequests.isEmpty)
    }

    private func makeRepositoryModel(repo: String) -> (NewSessionVM, HostedListingUseCase, MockNewSessionRouting) {
        let catalog = BackendCatalog(entries: [BackendControlFixtures.entry("claude", installed: true)], state: .available)
        let useCase = HostedListingUseCase(catalog: catalog, listings: [:], missingPaths: ["/fixture/repos/\(Self.missingName)"])
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
