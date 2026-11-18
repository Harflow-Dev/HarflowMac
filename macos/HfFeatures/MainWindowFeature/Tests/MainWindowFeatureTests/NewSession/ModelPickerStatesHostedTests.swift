import AppKit
import Combine
import Foundation
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - HostedListingUseCase

/// A use case with a fixed listing per harness; a harness listed in `pending` never answers, so its
/// Model field stays in the loading state.
@MainActor
final class HostedListingUseCase: NewSessionUseCase {
    let base = MockNewSessionUseCase()
    private let catalog: BackendCatalog
    private let listings: [String: ModelListing]
    private let pending: Set<String>
    private let taskList: [TaskInfo]
    private let missingPaths: Set<String>

    /// `taskList` is what the recents are built from; `missingPaths` are reported as not existing on disk.
    init(
        catalog: BackendCatalog, listings: [String: ModelListing], pending: Set<String> = [],
        taskList: [TaskInfo] = [], missingPaths: Set<String> = []
    ) {
        self.catalog = catalog
        self.listings = listings
        self.pending = pending
        self.taskList = taskList
        self.missingPaths = missingPaths
        given(base).qualificationSession().willReturn(QualificationFixture.readySession())
        given(base).tasks.willReturn([])
    }

    func qualificationSession() -> QualificationSession { base.qualificationSession() }
    func resolvedRepoPath(_ input: String) -> String? { input }
    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String { "task" }
    var tasks: [TaskInfo] { taskList }
    func existingDirectories(among paths: [String]) async -> Set<String> { Set(paths).subtracting(missingPaths) }
    var agentUsageSnapshot: AgentUsageSnapshot { .init() }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { Just(.init()).eraseToAnyPublisher() }
    var backendCatalog: BackendCatalog { catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { Empty().eraseToAnyPublisher() }

    func modelListing(for backend: String) async -> ModelListing {
        if pending.contains(backend) {
            // Never answers until the surrounding task is cancelled (the view model's teardown).
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        }
        return listings[backend] ?? .unreadable
    }

    func refreshModelListing(for backend: String) async -> ModelListing { await modelListing(for: backend) }
}

// MARK: - ModelPickerStatesHostedTests

/// Hosted evidence for the Model field's listing states in the open harness popover: the note and "Try
/// again" the real view model produces, the field's accessibility hint, the removed "Use default model"
/// button, and (when `HARFLOW_MODEL_PICKER_CAPTURE_DIR` is set) light and dark captures at both approved
/// sizes. Activation of the AppKit host can fail while another app is frontmost.
@MainActor
@Suite(.serialized)
struct ModelPickerStatesHostedTests {

    // MARK: - Scenarios

    enum Scenario: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case loading, unavailableSourceMissing, unavailableExitNonzero, notInstalled, truncated, truncatedDropped, empty, defaultTag, harnessOpen
        var testDescription: String { rawValue }

        var backend: String {
            switch self {
            case .loading: "claude"
            case .unavailableSourceMissing, .empty: "codex"
            case .unavailableExitNonzero, .truncated, .truncatedDropped: "opencode"
            case .notInstalled: "antigravity"
            case .defaultTag: "cursor"
            case .harnessOpen: "gated"
            }
        }

        var expectedNote: String? {
            switch self {
            case .loading: "Loading suggested models… You can still type a model name."
            case .unavailableSourceMissing:
                "Suggested models aren't available. Codex's model cache wasn't found. You can still type a model name."
            case .unavailableExitNonzero:
                "Suggested models aren't available. Opencode stopped with an error while listing its models. You can still type a model name."
            case .notInstalled: "Antigravity wasn't found on your PATH — starting this harness may fail."
            case .truncated: "Showing the first 400 models Opencode listed. You can type a model name that isn't shown."
            case .truncatedDropped:
                "Showing the first 400 models Opencode listed. You can type a model name that isn't shown. "
                    + "3 entries were invalid or repeated and were left out."
            case .empty: "Codex lists no models. You can still type a model name."
            case .defaultTag, .harnessOpen: nil
            }
        }

        /// What describes the Model field: the model note, or the harness popover's own note when the field has none.
        var expectedHint: String? {
            switch self {
            case .defaultTag: nil
            case .harnessOpen: "The requested harness gated is unavailable in the current catalog. Choose a harness explicitly."
            default: expectedNote
            }
        }

        /// Whether the Model field has a note of its own (a not-installed harness's note comes from the harness popover).
        var hasModelNote: Bool { expectedNote != nil && self != .notInstalled }

        var showsRetry: Bool { self == .unavailableSourceMissing || self == .unavailableExitNonzero }
    }

    private static func rows(_ count: Int) -> [ModelOption] {
        (1 ... count).map { ModelOption(value: "openai/model-\($0)", label: "Model \($0)") }
    }

    private func makeViewModel(_ scenario: Scenario) -> NewSessionVM {
        let names = ["claude", "codex", "opencode", "vibe", "antigravity", "cursor"]
        let catalog = BackendCatalog(
            entries: names.map { BackendControlFixtures.entry($0, installed: $0 == "antigravity" ? false : true) }, state: .available
        )
        let listings: [String: ModelListing] = [
            "codex": scenario == .empty
                ? ModelListing(state: .available)
                : ModelListing(state: .unavailable(.sourceMissing), source: .harnessCache),
            "opencode": scenario == .unavailableExitNonzero
                ? ModelListing(state: .unavailable(.exitNonzero))
                : ModelListing(state: .available, options: Self.rows(400), truncated: true, droppedCount: scenario == .truncatedDropped ? 3 : 0),
            "antigravity": ModelListing(state: .notInstalled),
            "cursor": ModelListing(state: .available, options: [
                ModelOption(value: "auto", label: "Auto", isDefault: true), ModelOption(value: "gpt-6-astra", label: "GPT 6 Astra")
            ])
        ]
        let useCase = HostedListingUseCase(
            catalog: catalog, listings: listings, pending: scenario == .loading ? ["claude"] : []
        )
        let sut = NewSessionVM(useCase: useCase, routing: MockNewSessionRouting())
        sut.didChangeBackend(scenario.backend)
        sut.didChangeRepo("/fixture/repository")
        return sut
    }

    // MARK: - Tests

    @Test(arguments: Scenario.allCases)
    func givenAListingState_whenTheHarnessPopoverIsHosted_thenItShowsTheApprovedNoteAndCapturesBothSizes(_ scenario: Scenario) async throws {
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)] {
            for dark in [false, true] {
                // given
                let viewModel = makeViewModel(scenario)
                let fixture = makeFixture(viewModel, size: size, dark: dark)
                defer { fixture.dispose() }

                // when
                try await activate(fixture.window)
                await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
                let popover = try #require(ownedPopovers(of: fixture.window).first, "The harness popover must open through the seam.")
                if let note = scenario.expectedNote {
                    await waitUntil(timeout: 8) { contains(note, in: popover) }
                } else {
                    await waitUntil(timeout: 3) { contains("Harness", in: popover) }
                }
                await DisplayFrames.waitForPresentedFrame()

                // then
                #expect(!contains("Use default model", in: popover), "The removed button must not return.")
                #expect(contains("Try again", in: popover) == scenario.showsRetry)
                if let note = scenario.expectedNote { #expect(contains(note, in: popover), "Note for \(scenario.rawValue)") }
                // The field is described by the model note, or by the harness's PATH or catalog note when there is none.
                #expect(modelFieldHint(in: popover) == scenario.expectedHint, "The field's hint for \(scenario.rawValue)")
                // The model-note element exists exactly when the Model field has a note of its own.
                #expect(hasElement(identifier: "new-session-model-note", in: popover) == (scenario.hasModelNote), "Model note element")
                let label = "\(scenario.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))"
                try capture(fixture.host, name: label + "-window")
                try capture(try #require(popover.contentView), name: label + "-popover")
                if scenario == .defaultTag, size.width > 1100 { try recordMenus(in: popover, name: label) }
                if scenario == .defaultTag, !dark, size.width > 1100 {
                    try await verifyDefaultTag(viewModel, popover: popover, name: label)
                }
                if scenario == .truncated, !dark, size.width > 1100 {
                    let rows = try openSuggestions(in: popover, name: label, expected: ["Default", "Model 1", "Model 2"])
                    #expect(rows != nil, "UNVERIFIED: the truncated suggestions menu could not be opened.")
                    #expect(rows?.contains { $0.title == "Model 1" } == true)
                }
            }
        }
    }

    // MARK: - Fixture

    @MainActor struct Fixture {
        let window: NSWindow
        let host: NSView
        let previousActivationPolicy: NSApplication.ActivationPolicy

        func dispose() {
            func popups(of window: NSWindow) -> [NSWindow] { (window.childWindows ?? []).flatMap { [$0] + popups(of: $0) } }
            for popup in popups(of: window).reversed() {
                popup.orderOut(nil)
                popup.close()
            }
            window.contentView = nil
            window.close()
            NSApp.setActivationPolicy(previousActivationPolicy)
        }
    }

    func makeFixture(
        _ viewModel: NewSessionVM, size: NSSize, dark: Bool, harnessPresented: Bool = true, repositoryPresented: Bool = false
    ) -> Fixture {
        _ = NSApplication.shared
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let controller = NSHostingController(
            rootView: NewSessionView(viewModel, repositoryPresented: repositoryPresented, harnessPresented: harnessPresented)
                .preferredColorScheme(dark ? .dark : .light)
        )
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        return Fixture(window: window, host: host, previousActivationPolicy: previous)
    }

    func activate(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 5) { NSApp.isActive && window.isKeyWindow }
        try #require(NSApp.isActive && window.isKeyWindow, "The AppKit host could not become the active key window.")
    }

    // MARK: - Inspection

    func ownedPopovers(of owner: NSWindow) -> [NSWindow] {
        func collect(_ window: NSWindow) -> [NSWindow] { (window.childWindows ?? []).flatMap { [$0] + collect($0) } }
        return collect(owner).filter(\.isVisible)
    }

    private func contains(_ text: String, in window: NSWindow) -> Bool { tree(window).contains { matches($0, text) } }

    private func matches(_ object: NSObject, _ text: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == text
        }
    }

    /// The accessibility hint (`accessibilityHelp`) of the element labelled "Model", or `nil`.
    private func modelFieldHint(in window: NSWindow) -> String? {
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        let helpSelector = NSSelectorFromString("accessibilityHelp")
        for object in tree(window) where object.responds(to: labelSelector) && object.responds(to: helpSelector) {
            guard object.perform(labelSelector)?.takeUnretainedValue() as? String == "Model" else { continue }
            if let hint = object.perform(helpSelector)?.takeUnretainedValue() as? String, !hint.isEmpty { return hint }
        }
        return nil
    }

    private func hasElement(identifier: String, in window: NSWindow) -> Bool {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return tree(window).contains { $0.responds(to: selector) && $0.perform(selector)?.takeUnretainedValue() as? String == identifier }
    }

    /// Opens the real suggestions menu with nothing selected and with Auto selected (the checked branch) and asserts the
    /// default row keeps its " default" run and its accessibility label in both.
    private func verifyDefaultTag(_ viewModel: NewSessionVM, popover: NSWindow, name: String) async throws {
        for selected in [false, true] {
            if selected {
                viewModel.didChangeModel("auto")
                await DisplayFrames.waitForPresentedFrame()
            }
            let suffix = selected ? "-selected" : ""
            let rows = try openSuggestions(in: popover, name: name + suffix, expected: ["Default", "GPT 6 Astra"])
            #expect(rows != nil, "UNVERIFIED: the default-tag suggestions menu could not be opened (selected: \(selected)).")
            guard let rows else { continue }
            let auto = rows.first { $0.title.hasPrefix("Auto") }
            #expect(auto != nil, "The Auto row must be present (selected: \(selected)).")
            #expect(auto?.runs.contains { $0.text == " default" } == true, "The default row needs a ' default' run (selected: \(selected)).")
            // The menu item's accessibility label is its plain title, "Auto default": a custom label does not reach it.
            #expect(auto?.accessibilityLabel == "Auto default", "VoiceOver label (selected: \(selected)): \(auto?.accessibilityLabel ?? "nil")")
            #expect(auto?.hasImage == selected, "The checked row carries the checkmark image (selected: \(selected)).")
            #expect(rows.first { $0.title == "GPT 6 Astra" }?.runs.contains { $0.text == " default" } != true)
        }
    }

    func tree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result = [object]
            if let window = object as? NSWindow, let content = window.contentView { result += collect(content) }
            if let view = object as? NSView { result += view.subviews.flatMap(collect) }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                result += children.flatMap(collect)
            }
            return result
        }
        return collect(root)
    }

    // MARK: - Evidence

    private var captureDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_MODEL_PICKER_CAPTURE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func capture(_ view: NSView, name: String) throws {
        guard let directory = captureDirectory else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Writes every native menu found in the popover (item titles and their attributed titles), which shows how
    /// a default row actually renders in the suggestions menu.
    private func recordMenus(in popover: NSWindow, name: String) throws {
        guard let directory = captureDirectory else { return }
        var lines: [String] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            if let button = view as? NSPopUpButton {
                // SwiftUI fills a Menu's items when it is about to open.
                if let menu = button.menu { menu.delegate?.menuNeedsUpdate?(menu) }
                lines.append("popup \(type(of: button)) enabled=\(button.isEnabled) items=\(button.menu?.items.count ?? 0)")
                for item in button.menu?.items ?? [] { lines.append(describe(item)) }
            }
            if let menu = view.menu { lines.append("view-menu \(type(of: view))"); for item in menu.items { lines.append(describe(item)) } }
            view.subviews.forEach(walk)
        }
        if let content = popover.contentView { walk(content) }
        lines.append("views: " + (popover.contentView.map(allClassNames) ?? []).joined(separator: ", "))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-menus.txt"), atomically: true, encoding: .utf8)
    }

    /// One native menu item as tracked.
    struct MenuItemSnapshot {
        let title: String
        /// The attributed title's runs as (text, colour description), empty when the item has none.
        let runs: [(text: String, color: String)]
        let accessibilityLabel: String?
        let state: Int
        /// SwiftUI draws the checkmark of a selected row as the item image.
        let hasImage: Bool
    }

    private final class SuggestionsRecord {
        var items: [MenuItemSnapshot] = []
        var windows: [String] = []
        var images: [Data] = []
        var found = false
    }

    private func snapshot(_ item: NSMenuItem) -> MenuItemSnapshot {
        var runs: [(String, String)] = []
        if let text = item.attributedTitle {
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                let color = (attributes[.foregroundColor] as? NSColor).map { "\($0)" } ?? "default"
                runs.append(((text.string as NSString).substring(with: range), color))
            }
        }
        let selector = NSSelectorFromString("accessibilityLabel")
        let label = item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() as? String : nil
        return MenuItemSnapshot(title: item.title, runs: runs, accessibilityLabel: label, state: item.state.rawValue, hasImage: item.image != nil)
    }

    /// Opens the suggestions menu through its native button, waits until every title in `expected` is present, and
    /// returns its items (and writes them, with a menu bitmap, when captures are on). `nil` means it could not be
    /// opened or the rows never appeared: the caller must report that as unverified. Both timers run in the
    /// common run-loop modes so they fire while the menu tracks; the second cancels tracking unconditionally.
    private func openSuggestions(in popover: NSWindow, name: String, expected: [String]) throws -> [MenuItemSnapshot]? {
        let candidates = tree(popover).compactMap { $0 as? NSPopUpButton }
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        let button = candidates.first { $0.responds(to: labelSelector) && $0.perform(labelSelector)?.takeUnretainedValue() as? String == "Suggested models" }
            ?? candidates.first { $0.menu?.items.isEmpty == true }
        guard let button, let menu = button.menu else {
            try writeSuggestions(name: name, lines: ["UNVERIFIED: no suggestions button found"], images: [])
            return nil
        }
        let record = SuggestionsRecord()
        nonisolated(unsafe) let unsafeMenu = menu
        nonisolated(unsafe) let unsafeRecord = record
        nonisolated(unsafe) let unsafeSelf = self
        let poll = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !unsafeRecord.found else { return }
                let titles = unsafeMenu.items.map(\.title)
                guard expected.allSatisfy(titles.contains) else { return }
                unsafeRecord.found = true
                unsafeRecord.items = unsafeMenu.items.map(unsafeSelf.snapshot)
                for window in NSApp.windows where window.isVisible {
                    let kind = String(describing: type(of: window))
                    unsafeRecord.windows.append("window \(kind) frame=\(window.frame)")
                    if kind.contains("Menu"), let content = window.contentView,
                       let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) { unsafeRecord.images.append(data) }
                    }
                }
                unsafeMenu.cancelTracking()
            }
        }
        let bound = Timer(timeInterval: 3, repeats: false) { _ in MainActor.assumeIsolated { unsafeMenu.cancelTracking() } }
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(bound, forMode: .common)
        button.performClick(nil)
        poll.invalidate()
        bound.invalidate()
        var lines = record.items.map { item in
            "  item title=\"\(item.title)\" runs=" + item.runs.map { "[\($0.text)|\($0.color)]" }.joined()
                + " accessibilityLabel=\(item.accessibilityLabel ?? "nil") state=\(item.state) image=\(item.hasImage)"
        } + record.windows
        if !record.found { lines.insert("UNVERIFIED: the expected rows never appeared in the tracked menu", at: 0) }
        try writeSuggestions(name: name, lines: lines, images: record.images)
        return record.found ? record.items : nil
    }

    private func writeSuggestions(name: String, lines: [String], images: [Data]) throws {
        guard let directory = captureDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-suggestions.txt"), atomically: true, encoding: .utf8)
        for (index, data) in images.enumerated() { try data.write(to: directory.appendingPathComponent("\(name)-suggestions-\(index).png")) }
    }

    private func describe(_ item: NSMenuItem) -> String {
        let shot = snapshot(item)
        return "  item title=\"\(shot.title)\" runs=" + shot.runs.map { "[\($0.text)|\($0.color)]" }.joined()
            + " accessibilityLabel=\(shot.accessibilityLabel ?? "nil") enabled=\(item.isEnabled) state=\(shot.state)"
    }

    private func allClassNames(_ view: NSView) -> [String] { [String(describing: type(of: view))] + view.subviews.flatMap(allClassNames) }
}
