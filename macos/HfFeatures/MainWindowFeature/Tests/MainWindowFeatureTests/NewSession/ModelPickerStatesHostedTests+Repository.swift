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

    private static let presentNames = [
        "HarflowEngine", "r10-workflow-definitions-e2f0c3",
        "a-very-long-repository-name-that-cannot-fit-on-one-line-anywhere-at-all", "HarflowDesign", "HarflowMCP"
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
        sut.didChangeRepo("/fixture/repository")
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
                        rect.width <= HfRadius.Metrics.recentRepoChipMaxWidth + 2 * HfRadius.Metrics.spacing8 + 1,
                        "\(name) must stay within the chip maximum (\(label)): \(rect.width)"
                    )
                    #expect(bounds.contains(rect), "\(name) must lie inside the popover (\(label)): \(rect) vs \(bounds)")
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
}
