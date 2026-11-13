import AppKit
import Foundation
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Testing

// MARK: - M05MatrixRunner

/// Mounts one M05 matrix state in the production shell with a real standalone `TaskDetailVM`, in both sizes and one
/// appearance, and runs the recipe's readiness wait, assertions and capture. Every suite goes through this runner so the
/// shell invariants and the evidence format are identical across the matrix.
@MainActor enum M05MatrixRunner {

    /// The mounted state a recipe asserts against.
    @MainActor struct Context {
        let fixture: TopBarIntegratedFixture
        let harness: TaskDetailVMTests.SUT
        let window: NSWindow
        let host: NSView
        let size: NSSize
        let dark: Bool
        let state: String
        let name: String

        var coordinator: MainWindowNavigationCoordinatorMock { fixture.coordinator }
        var vm: TaskDetailVM { harness.sut }

        /// Whether the window's accessibility tree holds an element labelled, titled, valued or identified `text`.
        func has(_ text: String) -> Bool { ShellMatrix.has(text, in: window) }

        /// Every element of the window's accessibility tree.
        var tree: [NSObject] { ShellMatrix.tree(window) }

        /// Whether any element's label, title or value contains `text`.
        func hasContaining(_ text: String) -> Bool {
            tree.contains { object in
                [ShellMatrix.label(object), ShellMatrix.value(object), ShellMatrix.string(object, "accessibilityTitle")].contains { $0?.contains(text) == true }
            }
        }

        /// Whether the subtree of the element identified `id` holds an element labelled, titled or valued `text`. Used for every
        /// landmark that could also appear in the sidebar, toolbar or badge.
        func within(_ id: String, has text: String) -> Bool {
            element(id).map { ShellMatrix.contains(text, in: $0) } ?? false
        }

        /// The first such element, for geometry, enabled and press checks.
        func element(_ text: String) -> NSObject? { ShellMatrix.element(text, in: window) }

        /// Whether the principal toolbar item draws an element whose label starts with `prefix`. Timers are excluded by
        /// matching the prefix, so "Running" matches "Running 04:12".
        func principalHas(prefix: String) -> Bool {
            guard let item = fixture.principalItem, let view = item.view else { return false }
            return fixture.elements(in: view).contains { object in
                [fixture.label(object), fixture.string(object, "accessibilityValue")].contains { $0?.hasPrefix(prefix) == true }
            }
        }

        /// Every label inside the principal item, for a failure message.
        var principalStrings: [String] { fixture.principalItem?.view.map { fixture.strings(in: $0) } ?? [] }
    }

    /// What a recipe builds before the shell mounts.
    @MainActor struct Built {
        let harness: TaskDetailVMTests.SUT
        /// Objects the scenario needs kept alive until the state is torn down (a continuation fixture, a read script).
        var retained: [AnyObject] = []
        /// Runs once the pane choices are stored, before the shell is built.
        var prepare: (@MainActor (TaskDetailVMTests.SUT) -> Void)?
    }

    /// One state's recipe.
    @MainActor struct Spec {
        let suite: String
        let state: String
        /// The window sizes this state mounts at. Defaults to both approved sizes.
        var sizes: [NSSize] = ShellMatrix.sizes
        /// Whether the sidebar starts collapsed.
        var collapsed = false
        /// The scenario's config; the runner overwrites size and appearance.
        var config: @MainActor (NSSize) -> TopBarIntegratedFixture.Config = { _ in .init() }
        var build: @MainActor () throws -> Built
        /// Drives transitions after the shell mounted (publishing subjects, pressing a control).
        var drive: (@MainActor (Context) async -> Void)?
        /// Whether the state is on screen; polled with the activation kept and the principal republished.
        var ready: @MainActor (Context) -> Bool
        var verify: @MainActor (Context) throws -> Void
        /// Runs after the capture, before teardown (releasing a held read, closing a sheet).
        var finish: (@MainActor (Context) async -> Void)?
    }

    /// Mounts and checks the spec at each of its sizes.
    static func run(_ spec: Spec, dark: Bool) async throws {
        for size in spec.sizes {
            let name = M05MatrixCapture.name(suite: spec.suite, state: spec.state, dark: dark, size: size)
            let built = try spec.build()
            var config = spec.config(size)
            config.width = size.width
            config.height = size.height
            config.dark = dark
            config.collapsed = spec.collapsed
            let fixture = await TopBarIntegratedFixture(config, harness: built.harness, prepare: built.prepare)
            defer {
                built.harness.sut.didDisappear()
                fixture.close()
                withExtendedLifetime(built.retained) {}
            }
            let host = try #require(fixture.window.contentView, "no host view \(name)")
            let context = Context(fixture: fixture, harness: built.harness, window: fixture.window, host: host,
                                  size: size, dark: dark, state: spec.state, name: name)
            // The activation is re-asserted while waiting: a one-off request can be lost to another application.
            await waitUntil(timeout: 15) {
                fixture.keepActive()
                fixture.pump()
                return NSApp.isActive && fixture.window.isKeyWindow
            }
            if let drive = spec.drive { await drive(context) }
            await waitUntil(timeout: 10) {
                fixture.keepActive()
                fixture.pump()
                if !config.loading { fixture.publish() }
                return spec.ready(context)
            }
            #expect(spec.ready(context), "state not ready: \(name); strings \(fixture.contentStrings.prefix(60))")
            await DisplayFrames.waitForPresentedFrame()
            #expect(fixture.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua),
                    "window appearance \(name)")
            try ShellMatrix.assertShellInvariants(fixture.window, host: host, size: size, collapsed: spec.collapsed,
                                                  coordinator: fixture.coordinator, name: name)
            do {
                try spec.verify(context)
                try await M05MatrixCapture.record(suite: spec.suite, state: spec.state, dark: dark, size: size,
                                                  window: fixture.window, host: host)
            } catch {
                // A failing check must not leave a held read (a ctl latch) behind.
                if let finish = spec.finish { await finish(context) }
                throw error
            }
            if let finish = spec.finish { await finish(context) }
        }
    }
}
