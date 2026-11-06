import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - M04StateMatrixHostedTests

/// Synthetic native evidence for HarflowDesign v2/docs/m04-proposal.md: baseline 5b37a3d,
/// amended by the currently approved design commit 9d64bfda. Captures require separate visual
/// review; these assertions do not establish pixel fidelity.
@MainActor
@Suite(.serialized)
struct M04StateMatrixHostedTests {
    private nonisolated static let states = [
        "shell", "shell-collapsed", "shell-narrow", "composer-loading", "composer-ready",
        "composer-unqualified", "composer-invalid", "composer-starting", "composer-refused",
        "composer-unknown", "advanced", "advanced-closed", "history-empty", "history-loading",
        "history-older", "history-error", "history-reconnecting", "history-retained",
        "runtime-checking", "runtime-install-required", "runtime-update-required",
        "runtime-installing", "runtime-failed", "runtime-listing"
    ]

    @Test(arguments: states, [false, true])
    func givenApprovedState_whenHostedInBothSizes_thenNativeStateAndAuthorityRemainExplicit(state: String, dark: Bool) async throws {
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)] {
            // given — preview models have no repositories, engine clients or provider actions.
            _ = NSApplication.shared
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApplication.shared.accessibilitySetValue(previous, forAttribute: enhanced) }
            let fixture = makeFixture(state)
            let coordinator = fixture.coordinator
            coordinator.sidebarViewModel.appAppearance = dark ? .dark : .light
            let originalComposer = coordinator.composerViewModel
            let originalTask = coordinator.retainedTaskViewModel
            let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
            let root = MainWindowNavigationView(coordinator, sidebarCollapsed: state == "shell-collapsed")
                .preferredColorScheme(dark ? .dark : .light)
                .environment(\.hfReduceMotionOverride, true)
            let controller = NSHostingController(rootView: root)
            controller.sceneBridgingOptions = .all
            let host = controller.view
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderFront(nil)
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            defer {
                for popup in NSApplication.shared.windows where !existing.contains(ObjectIdentifier(popup)) && popup !== window {
                    popup.orderOut(nil)
                    popup.close()
                }
                window.contentViewController = nil
                window.close()
            }

            // when — layout readiness is observed, never inferred from a delay.
            await waitUntil(timeout: 5) {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                return NSApp.isActive && (window.isKeyWindow || window.isMainWindow)
                    && fixture.landmarks.allSatisfy { contains($0, in: window) }
                    && sidebarLayoutIsReady(fixture, host: host)
                    && M04ToolbarEvidence.isPopulated(window)
            }
            if fixture.optionsOpen {
                await waitUntil(timeout: 5) {
                    newPopupWindows(existing: existing, main: window).contains { contains("Task options", in: $0) }
                }
            }

            await DisplayFrames.waitForPresentedFrame()
            let context = HostedState(state: state, size: size, dark: dark,
                                      originalComposer: originalComposer, originalTask: originalTask)
            try assertState(context, window: window, host: host, fixture: fixture)
            let name = context.name
            try await capture(host, name: name, window: window)
            try await captureOptions(fixture, existing: existing, window: window, name: name)
        }
    }

    private func sidebarLayoutIsReady(_ fixture: Fixture, host: NSView) -> Bool {
        let model = fixture.coordinator.sidebarViewModel
        guard model.runtimeSetupState.isReady else { return true }
        if model.sections.contains(where: { $0.bucket == .running && !$0.items.isEmpty }) {
            guard let outline = sidebarFixtureOutline(in: host, role: .running), outline.numberOfRows > 0,
                  let scroll = outline.enclosingScrollView, scroll.frame.height > 0 else { return false }
        }
        if model.sections.contains(where: { $0.bucket != .running && !$0.items.isEmpty }) {
            guard let outline = sidebarFixtureOutline(in: host), outline.numberOfRows > 0,
                  let scroll = outline.enclosingScrollView, scroll.frame.height > 0 else { return false }
        }
        return true
    }

    private func captureOptions(_ fixture: Fixture, existing: Set<ObjectIdentifier>, window: NSWindow, name: String) async throws {
        if fixture.optionsOpen {
            let popup = try #require(newPopupWindows(existing: existing, main: window).first { contains("Task options", in: $0) })
            let content = try #require(popup.contentView)
            #expect(content.bounds.width > 0)
            #expect(content.bounds.height <= 450)
            #expect(contains("Turn limit", in: popup))
            try await capture(content, name: name + "-options", window: popup)
        }
    }

    private struct HostedState {
        let state: String
        let size: NSSize
        let dark: Bool
        let originalComposer: NewSessionViewModelMock
        let originalTask: TaskDetailViewModelMock

        /// The capture artifact name for this exact state/color/size, shared with the capture
        /// helpers so diagnostics land next to the evidence they explain.
        var name: String { "\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))" }
    }

    private func assertState(_ context: HostedState, window: NSWindow, host: NSView, fixture: Fixture) throws {
        let state = context.state
        let size = context.size
        let originalComposer = context.originalComposer
        let originalTask = context.originalTask
        let coordinator = fixture.coordinator
        // then — each route must expose its own state, including closed outcome evidence.
        for landmark in fixture.landmarks { #expect(contains(landmark, in: window), "Missing \(state): \(landmark)") }
        #expect(abs(host.bounds.width - size.width) < 1)
        #expect(abs(host.bounds.height - size.height) < 1)
        #expect(window.frame.height > host.bounds.height)
        #expect(coordinator.composerViewModel === originalComposer)
        #expect(coordinator.retainedTaskViewModel === originalTask)
        #expect(coordinator.sidebarViewModel.runtimeSetupTapCount == 0)
        #expect(coordinator.sidebarViewModel.newSessionTapCount == 0)
        #expect(coordinator.listingRetryCount == 0)
        #expect(!contains("Search", in: window))
        #expect(!contains("Filter by backend", in: window))
        #expect(!descendants(host).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" })
        if state.hasPrefix("runtime-") {
            #expect(!contains("Task prompt", in: window))
            #expect(!contains("Start task", in: window))
        }
        if state == "runtime-listing" {
            #expect(coordinator.runtimeIsReady)
            #expect(!contains("Install runtime", in: window))
            #expect(!contains("Retry setup", in: window))
        }
        try assertNavigationGeometry(window, host: host, collapsed: state == "shell-collapsed", name: context.name)
        try assertToolbarOwnsOnlyTheContextTitle(window, coordinator: coordinator, name: context.name)
        if fixture.isComposer {
            try assertComposer(window, host: host, fixture: fixture)
        }
        if state == "history-retained" {
            #expect(coordinator.selection == .task(originalTask.taskID))
            #expect(coordinator.sidebarViewModel.sections.count == 1)
            #expect(coordinator.sidebarViewModel.sections[0].bucket == .earlier)
            #expect(contains(originalTask.title, in: window))
        }
    }

    struct Fixture {
        let coordinator: MainWindowNavigationCoordinatorMock
        var landmarks = ["What should we work on?", "More task options"]
        var optionsOpen = false
        var isComposer = true
        var startEnabled = false
    }

    func makeFixture(_ state: String) -> Fixture {
        let coordinator = MainWindowNavigationCoordinatorMock()
        let composer = coordinator.composerViewModel
        composer.repo = "/fixture/repository"
        var fixture = Fixture(coordinator: coordinator)
        if state.hasPrefix("composer-") || state.hasPrefix("advanced") {
            composer.message = "Review the delivery queue"
            fixture.startEnabled = true
        }
        switch state {
        case "composer-loading", "composer-unqualified":
            let checking = state == "composer-loading"
            composer.qualificationCards = [.init(id: "fixture", model: .init(
                identity: "Fixture harness", state: checking ? .checking : .unavailable,
                message: checking ? "Checking fixture qualification." : "Fixture qualification unavailable.", features: []))]
            let title = checking ? HarnessQualificationModel.State.checking.title : HarnessQualificationModel.State.unavailable.title
            fixture.landmarks.append("Harness qualification: \(title). \(composer.qualificationCards[0].model.message)")
            fixture.startEnabled = false
        case "composer-invalid":
            composer.turnLimit = "0"
            composer.turnLimitError = "Enter a whole number above 0, or leave it empty for the default."
            composer.validationMessages = [composer.turnLimitError!]
            fixture.landmarks.append(composer.validationMessages[0])
            fixture.optionsOpen = true
            fixture.startEnabled = false
        case "composer-starting":
            composer.composerState = .submitting
            composer.isStarting = true
            fixture.landmarks.append("Starting task")
            fixture.startEnabled = false
        case "composer-refused":
            composer.composerState = .refused
            composer.errorText = "Start was refused. Review the settings and try again."
            fixture.landmarks += [composer.errorText!, "Review settings"]
            fixture.startEnabled = false
        case "composer-unknown":
            composer.composerState = .unknown
            fixture.landmarks += ["The start outcome is unknown. Review Recent work before starting another task.", "Review Recent work"]
            fixture.startEnabled = false
        case "advanced": fixture.optionsOpen = true
        case "advanced-closed": composer.effort = "high"
        case "history-empty":
            coordinator.sidebarViewModel.sections = []
            coordinator.sidebarViewModel.emptyStateMessage = "No recent work yet."
            fixture.landmarks.append("No recent work yet.")
        case "history-loading":
            coordinator.sidebarViewModel.sections = []
            coordinator.sidebarViewModel.taskHistoryState.isLoading = true
            fixture.landmarks.append("Loading tasks…")
        case "history-older", "history-error", "history-reconnecting", "history-retained":
            configureHistory(state, fixture: &fixture)
        default: break
        }
        configureRuntime(state, fixture: &fixture)
        coordinator.sidebarViewModel.runtimeSetupState = coordinator.runtimeSetupState
        coordinator.optionsInitiallyPresented = fixture.optionsOpen
        return fixture
    }

    private func configureHistory(_ state: String, fixture: inout Fixture) {
        let coordinator = fixture.coordinator
        coordinator.selection = .task(coordinator.retainedTaskViewModel.taskID)
        coordinator.sidebarViewModel.selection = coordinator.selection
        fixture.isComposer = false
        fixture.landmarks = [coordinator.retainedTaskViewModel.title, "Looked at the failing test."]
        if state == "history-older" {
            coordinator.sidebarViewModel.taskHistoryState.hasMore = true
            fixture.landmarks.append("Load older tasks")
        } else if state == "history-error" {
            coordinator.sidebarViewModel.taskHistoryState.error = ToolError.timedOut(tool: "harflow-ctl", seconds: 30)
            fixture.landmarks.append("Retry tasks")
        } else if state == "history-reconnecting" {
            coordinator.sidebarViewModel.isConnected = false
            coordinator.loadingWorkError = "Reconnecting. Retaining loaded work."
            coordinator.sidebarViewModel.listErrorMessage = "Reconnecting. Retaining loaded work."
            fixture.landmarks.append("Reconnecting. Retaining loaded work.")
        } else {
            coordinator.sidebarViewModel.sections = Array(SidebarViewModelMock.defaultSections.suffix(1))
        }
    }

    private func configureRuntime(_ state: String, fixture: inout Fixture) {
        let coordinator = fixture.coordinator
        if state.hasPrefix("runtime-") {
            fixture.isComposer = false
            coordinator.runtimeIsReady = false
            switch state {
            case "runtime-checking":
                coordinator.runtimeSetupState = .checking
                fixture.landmarks = ["Checking Harflow runtime"]
            case "runtime-install-required":
                coordinator.runtimeSetupState = .installationRequired(installedVersion: nil, requiredVersion: "0.0.10")
                fixture.landmarks = ["Set up Harflow", "Install runtime"]
            case "runtime-update-required":
                coordinator.runtimeSetupState = .installationRequired(installedVersion: "0.0.9", requiredVersion: "0.0.10")
                fixture.landmarks = ["Update required", "Update runtime"]
            case "runtime-installing":
                coordinator.runtimeSetupState = .installing
                fixture.landmarks = ["Installing runtime"]
            case "runtime-failed":
                coordinator.runtimeSetupState = .failed("Synthetic installation failure; no installation attempted.")
                fixture.landmarks = ["Setup could not finish", "Retry setup", coordinator.runtimeSetupState.detail]
            default:
                coordinator.runtimeIsReady = true
                coordinator.hasLoadedWork = false
                fixture.landmarks = ["Runtime ready", "Loading your work for the first time…"]
            }
        }
    }

    private func assertComposer(_ window: NSWindow, host: NSView, fixture: Fixture) throws {
        let composer = fixture.coordinator.composerViewModel
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == composer.message })
        #expect(editor.isEditable == !composer.optionsLocked)
        #expect(editor.bounds.width > 0 && editor.bounds.width <= 720)
        let start = try #require(tree(window).first { matches($0, "Starting task") || matches($0, "Start task") })
        let startFrame = try #require(accessibilityFrame(start))
        #expect(abs(startFrame.width - HfRadius.Metrics.segmentedHeight) < 1)
        #expect(abs(startFrame.height - HfRadius.Metrics.segmentedHeight) < 1)
        let enabled = NSSelectorFromString("isAccessibilityEnabled")
        #expect(start.responds(to: enabled))
        #expect(start.value(forKey: "accessibilityEnabled") as? Bool == fixture.startEnabled)
        if !fixture.optionsOpen {
            #expect(newPopupWindows(existing: [], main: window).allSatisfy { !contains("Task options", in: $0) })
        }
        if composer.composerState == .unknown {
            #expect(!contains("Review settings", in: window))
            #expect(composer.message == "Review the delivery queue")
        }
    }

    private func assertNavigationGeometry(_ window: NSWindow, host: NSView, collapsed: Bool, name: String) throws {
        let settings = try #require(tree(window).first { matches($0, "Settings") })
        let frame = try #require(accessibilityFrame(settings))
        let content = window.convertToScreen(host.bounds)
        #expect(frame.width > 0 && frame.height > 0)
        #expect(content.insetBy(dx: -1, dy: -1).contains(frame))
        if collapsed {
            let rail = try #require(tree(window).first { matches($0, "Navigation rail") })
            let railFrame = try #require(accessibilityFrame(rail))
            #expect(abs(railFrame.width - 56) < 1)
            #expect(contains("Change appearance", in: window))
            #expect(contains("Expand sidebar", in: window))
            if !contains("Change appearance", in: window) {
                try captureCollapsedRailDiagnostics(window: window, rail: rail, name: name)
            }
        } else {
            let sidebars = tree(window).filter { hasIdentifier($0, "main-window-sidebar") }
            #expect(sidebars.count == 1, "Measure the unique semantic sidebar, never an incidental split child")
            let sidebar = try #require(sidebars.first)
            let sidebarFrame = try #require(accessibilityFrame(sidebar))
            #expect(abs(sidebarFrame.width - 264) < 1)
            #expect(content.insetBy(dx: -1, dy: -1).contains(sidebarFrame))
            #expect(contains("Collapse sidebar", in: window))
        }
    }

    func hasIdentifier(_ object: NSObject, _ identifier: String) -> Bool {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to: selector) && object.perform(selector)?.takeUnretainedValue() as? String == identifier
    }

    /// Bounded collapsed-rail AX diagnostic, written under the existing capture directory only
    /// when the expected `Change appearance` name is absent: the owned rail's public AX tree
    /// (role, identifier, label, title, value, description, help and action names per node)
    /// plus the native controls — `NSButton`/`NSPopUpButton` — whose frames intersect the
    /// rail's own accessibility frame, since a virtual rail AX node may expose no children of
    /// its own. Safe selector/KVC probes only — no AX action is invoked and no other window
    /// is touched.
    private func captureCollapsedRailDiagnostics(window: NSWindow, rail: NSObject, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        var railTreeNodes: [[String: Any]] = []
        var visited = Set<ObjectIdentifier>()
        func record(_ object: NSObject, depth: Int) {
            guard railTreeNodes.count < 128, depth <= 12, visited.insert(ObjectIdentifier(object)).inserted else { return }
            var node = axAttributes(of: object)
            node["depth"] = depth
            railTreeNodes.append(node)
            for child in axChildren(of: object).prefix(16) { record(child, depth: depth + 1) }
        }
        record(rail, depth: 0)
        let railFrame = accessibilityFrame(rail)
        let nativeControls = ownedNativeControlRecords(window: window, railFrame: railFrame)
        var outlines: [[String: Any]] = []
        if let contentView = window.contentView {
            for outline in descendants(contentView).compactMap({ $0 as? NSOutlineView }).prefix(4) {
                var rows: [[String: Any]] = []
                for row in 0 ..< min(outline.numberOfRows, 64) {
                    guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
                    var entry = axAttributes(of: rowView)
                    entry["rowIndex"] = row
                    let children = axChildren(of: rowView).prefix(8).map { axAttributes(of: $0) }
                    if !children.isEmpty { entry["axChildren"] = Array(children) }
                    rows.append(entry)
                }
                outlines.append(["type": String(describing: type(of: outline)),
                                  "identifier": outline.identifier?.rawValue ?? "none",
                                  "rows": rows] as [String: Any])
            }
        }
        let payload: [String: Any] = ["expectedName": "Change appearance",
                                      "railFrame": railFrame.map { NSStringFromRect($0) } ?? "none",
                                      "railTree": railTreeNodes,
                                      "nativeControls": nativeControls,
                                      "outlines": outlines] as [String: Any]
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent(name + "-collapsed-rail-ax.json"))
    }

    private func ownedNativeControlRecords(window: NSWindow, railFrame: NSRect?) -> [[String: Any]] {
        var nativeControls: [[String: Any]] = []
        if let railFrame, let contentView = window.contentView {
            for view in descendants(contentView) where view is NSButton {
                let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
                guard screenFrame.intersects(railFrame) else { continue }
                var entry = axAttributes(of: view)
                entry["identifier"] = view.identifier?.rawValue ?? "none"
                entry["frame"] = NSStringFromRect(view.frame)
                entry["bounds"] = NSStringFromRect(view.bounds)
                entry["screenFrame"] = NSStringFromRect(screenFrame)
                if view.responds(to: NSSelectorFromString("isEnabled")) {
                    entry["enabled"] = (view.value(forKey: "isEnabled") as? Bool) ?? false
                }
                nativeControls.append(entry)
                if nativeControls.count >= 16 { break }
            }
        }
        return nativeControls
    }

    /// The public AX attributes one node exposes: absent attributes are omitted, never guessed.
    private func axAttributes(of object: NSObject) -> [String: Any] {
        var entry: [String: Any] = ["type": String(describing: type(of: object))]
        for (key, attribute) in [("role", "accessibilityRole"), ("identifier", "accessibilityIdentifier"),
                                 ("label", "accessibilityLabel"), ("title", "accessibilityTitle"),
                                 ("value", "accessibilityValue"), ("description", "accessibilityRoleDescription"),
                                 ("help", "accessibilityHelp")] {
            if let text = axText(of: object, attribute) { entry[key] = text }
        }
        let actions = NSSelectorFromString("accessibilityActionNames")
        if object.responds(to: actions), let names = object.perform(actions)?.takeUnretainedValue() as? [Any] {
            entry["actions"] = names.compactMap { $0 as? String }
        }
        return entry
    }

    /// A guarded string-attribute probe through the selector ABI.
    private func axText(of object: NSObject, _ attribute: String) -> String? {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The node's public AX children, read through the same safe ABI as the tree walker.
    private func axChildren(of object: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [] }
        return children
    }

    func accessibilityFrame(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }

    private func newPopupWindows(existing: Set<ObjectIdentifier>, main: NSWindow) -> [NSWindow] {
        NSApplication.shared.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0 !== main && $0.isVisible }
    }

    func contains(_ text: String, in window: NSWindow) -> Bool { tree(window).contains { matches($0, text) } }

    func matches(_ object: NSObject, _ text: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == text
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

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func capture(_ host: NSView, name: String, window: NSWindow) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + "-host-bitmap.png"))
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
        let geometry = ["content": NSStringFromRect(host.bounds), "outerWindow": NSStringFromRect(window.frame),
                        "contentLayout": NSStringFromRect(window.contentLayoutRect), "reduceMotion": "true",
                        "designCommit": "9d64bfda7bed735d42c761c3149516c7f3e6ca01",
                        "baselineDesignCommit": "5b37a3d4d4d06b3d96c517cd384892e1ac6883cf",
                        "captureMethod": "window-server exact owned window", "hostBitmap": name + "-host-bitmap.png"]
        try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }
}
