import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - CenteredComposerHostedTests

/// Hosted native evidence for the approved centered New Session composer: the complete
/// heading/composer/outcome/help group centered on the 22 pt line grid, the self-sizing prompt
/// editor measured by the same TextKit layout that renders, and the + options popover adapting
/// to the actual available viewport. Uses only the established AppKit hosting and strict wait
/// helpers; no arbitrary sleeps.
@MainActor
@Suite(.serialized)
struct CenteredComposerHostedTests {
    private static let helpText = "⌘↩ to start. Choices are remembered per repository in this window."

    @Test(arguments: [false, true])
    func givenCenteredEmptyComposer_whenHostedAtApprovedSizes_thenTheGroupCentersOnTheLineGrid(dark: Bool) async throws {
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)] {
            // given — the real New Session view at both approved hosted sizes.
            let fixture = try makeHostedFixture(
                model: NewSessionViewModelMock(repo: "/fixture/repository", message: ""),
                size: size, dark: dark
            )
            defer { fixture.dispose() }

            // when — layout readiness is observed, never inferred from a delay.
            try await activate(fixture.window)
            await waitUntil(timeout: 5) {
                fixture.host.layoutSubtreeIfNeeded()
                return descendants(fixture.host).contains { $0 is ComposerPromptScrollView }
            }
            await DisplayFrames.waitForPresentedFrame()
            let prompt = try #require(
                descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first,
                "The centered composer must host its real native prompt editor."
            )

            // then — the empty draft takes the one-line floor inside the 720-point group.
            #expect(abs(prompt.bounds.height - ComposerSizing.floorHeight) < 0.5)
            #expect(abs(prompt.bounds.width - 688) < 1)
            #expect(contains("Describe the task.", in: fixture.window))

            // and — the complete group centers: symmetric gaps outside its 24-point padding.
            let heading = try #require(accessibilityFrame(in: fixture.window, text: "What should we work on?"),
                                       "The heading's public accessibility frame must be measurable.")
            let help = try #require(accessibilityFrame(in: fixture.window, text: Self.helpText),
                                    "The help line's public accessibility frame must be measurable.")
            let screen = fixture.window.convertToScreen(fixture.host.bounds)
            #expect(abs(heading.midX - screen.midX) < 1)
            #expect(abs(help.midX - screen.midX) < 1)
            let gapTop = screen.maxY - heading.maxY
            let gapBottom = help.minY - screen.minY
            #expect(gapTop >= 23.5)
            #expect(abs(gapTop - gapBottom) < 1)
            try capture(fixture.host, name: "centered-\(dark ? "dark" : "light")-\(Int(size.width))")
        }
    }

    @Test func givenGrowingDraft_whenHosted_thenTheEditorFollowsTheApprovedLineSteps() async throws {
        // given — empty draft, then growth past the cap and a shrink back to the floor.
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "")
        let fixture = try makeHostedFixture(model: model, size: NSSize(width: 1000, height: 620), dark: false)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return descendants(fixture.host).contains { $0 is ComposerPromptScrollView }
        }
        let prompt = try #require(descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first)
        let identity = ObjectIdentifier(prompt)

        // when / then — 1, 3 and 6 draft lines size the editor through the actual TextKit layout.
        let steps: [(message: String, height: CGFloat)] = [
            (draft(passages: 1), ComposerSizing.floorHeight),
            (draft(passages: 3), 3 * ComposerSizing.lineHeight + 2 * ComposerSizing.verticalInset),
            (draft(passages: 6), ComposerSizing.capHeight),
            (draft(passages: 9), ComposerSizing.capHeight)
        ]
        for step in steps {
            model.message = step.message
            await waitUntil(timeout: 5) {
                fixture.host.layoutSubtreeIfNeeded()
                return abs(prompt.bounds.height - step.height) < 0.5
            }
            #expect(abs(prompt.bounds.height - step.height) < 0.5, "Draft must size to \(step.height).")
        }
        #expect(prompt.documentHeight(width: prompt.contentView.bounds.width) > ComposerSizing.capHeight)

        // when — the draft shrinks again through the model update.
        model.message = draft(passages: 1)

        // then — the same editor instance shrinks back to the floor.
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return abs(prompt.bounds.height - ComposerSizing.floorHeight) < 0.5
        }
        #expect(abs(prompt.bounds.height - ComposerSizing.floorHeight) < 0.5)
        #expect(ObjectIdentifier(prompt) == identity)
    }

    @Test func givenCappedDraft_whenHosted_thenThePromptKeepsNativeSmallOverlayChrome() async throws {
        // given — a draft beyond the six-line cap.
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: draft(passages: 10))
        let fixture = try makeHostedFixture(model: model, size: NSSize(width: 1000, height: 620), dark: false)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return abs((descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first?.bounds.height ?? 0)
                - ComposerSizing.capHeight) < 0.5
        }
        let prompt = try #require(descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first)

        // then — the capped editor keeps the composer's existing scoped native scroll chrome.
        #expect(prompt.scrollerStyle == .overlay)
        #expect(prompt.verticalScroller?.controlSize == .small)
        #expect(prompt.autohidesScrollers)
        let width = prompt.contentView.bounds.width
        #expect(prompt.documentHeight(width: width) > prompt.contentView.bounds.height)

        // and — the caret stays reachable at the scrolling cap.
        let editor = prompt.promptTextView
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        editor.scrollRangeToVisible(end)
        let caret = try localCaret(of: end, in: editor)
        let visible = editor.visibleRect
        #expect(caret.minY >= visible.minY - 1 && caret.maxY <= visible.maxY + 1)
    }

    @Test(arguments: [(1000, 620, 400.0), (760, 420, 372.0)])
    func givenOpenOptions_whenHostedAtDifferentViewports_thenThePopoverAdaptsToTheAvailableHeight(
        width: Int, height: Int, expectedHeight: CGFloat
    ) async throws {
        // given — the + options popover presented up front (viewport height minus its two paddings).
        let model = NewSessionViewModelMock(backend: "vibe", repo: "/fixture/repository", message: "Fixture draft")
        model.effort = "retained-effort"
        let fixture = try makeHostedFixture(
            model: model,
            size: NSSize(width: width, height: height),
            dark: false,
            optionsPresented: true
        )
        defer { fixture.dispose() }
        try await activate(fixture.window)

        // when
        await waitUntil(timeout: 5) {
            optionFields(ownedBy: fixture.window).contains { $0.stringValue == "retained-effort" }
        }
        let popup = try #require(ownedPopovers(of: fixture.window).first)
        let content = try #require(popup.contentView)

        // then — the popover itself adapts, bounded by this window's actual viewport height.
        #expect(abs(content.bounds.width - 360) < 1)
        #expect(abs(content.bounds.height - expectedHeight) < 1)
        let fields = optionFields(ownedBy: fixture.window)
        let effort = try #require(fields.first { $0.stringValue == "retained-effort" })
        #expect(effort.isEditable)
    }

    @Test func givenOpenOptions_whenEscapeIsPressed_thenThePopoverClosesAndTheAnchorCollapses() async throws {
        // given — the popover open with its first option focused, in an active key window.
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Fixture draft")
        let fixture = try makeHostedFixture(
            model: model,
            size: NSSize(width: 1000, height: 620),
            dark: false,
            optionsPresented: true
        )
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            !optionFields(ownedBy: fixture.window).isEmpty
        }
        let keyWindow = try #require(NSApp.keyWindow, "Escape routing requires the current key window.")

        // when — Escape is delivered as a real key event to the window that owns first response.
        try sendKey("\u{1B}", code: 53, to: keyWindow)
        await waitUntil(timeout: 5) {
            optionFields(ownedBy: fixture.window).isEmpty && ownedPopovers(of: fixture.window).isEmpty
        }

        // then — the popover closes, the anchor reports collapsed, and the composer stays editable.
        let anchor = try #require(tree(fixture.window).first { matches($0, "More task options") })
        let valueSelector = NSSelectorFromString("accessibilityValue")
        #expect(anchor.responds(to: valueSelector))
        #expect(anchor.perform(valueSelector)?.takeUnretainedValue() as? String == "collapsed")
        let editor = try #require(descendants(fixture.host).compactMap { $0 as? NSTextView }.first { $0.string == model.message })
        #expect(editor.isEditable)
        #expect(model.message == "Fixture draft")
    }

    @Test func givenDraftBeyondTheCap_whenHosted_thenTheEditorCapsAndScrollsTheWholeDocument() async throws {
        // given — eight real lines hosted through the actual representable at a fixed width.
        let fixture = try makeEditorWindowHost(DraftHost(text: draftLines(8)))
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return abs((descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first?.bounds.height ?? 0)
                - ComposerSizing.capHeight) < 0.5
        }
        let prompt = try #require(descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first)

        // when — the whole document is measured by the same TextKit layout that renders.
        let width = prompt.contentView.bounds.width

        // then — the frame caps while the document stays fully scrollable.
        #expect(abs(prompt.frameHeight(width: width) - ComposerSizing.capHeight) < 0.5)
        #expect(prompt.documentHeight(width: width) > ComposerSizing.capHeight)
        let editor = prompt.promptTextView
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        editor.scrollRangeToVisible(end)
        let caret = try localCaret(of: end, in: editor)
        let visible = editor.visibleRect
        #expect(caret.minY >= visible.minY - 1 && caret.maxY <= visible.maxY + 1)
    }

    @Test func givenHostedDraft_whenNativeTextGrowsThenDeletes_thenTheEditorGrowsAndShrinks() async throws {
        // given — the real representable, updated only through the binding.
        let fixture = try makeEditorWindowHost(DraftHost(text: "Start draft"))
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return descendants(fixture.host).contains { ($0 as? ComposerPromptScrollView)?.promptTextView.string == "Start draft" }
        }
        let prompt = try #require(descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first)
        let editor = prompt.promptTextView
        let identity = ObjectIdentifier(editor)

        // when — typing appends a real second line through the native text view.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("\nTyped second line")

        // then — the editor grows to exactly two approved lines.
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return abs(prompt.bounds.height - 48) < 0.5
        }
        #expect(abs(prompt.bounds.height - 48) < 0.5)

        // when — deleting the whole draft through the same native path.
        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))

        // then — the editor shrinks back to the floor, same editor instance.
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return editor.string.isEmpty && abs(prompt.bounds.height - ComposerSizing.floorHeight) < 0.5
        }
        #expect(editor.string.isEmpty)
        #expect(ObjectIdentifier(editor) == identity)
    }

    @Test func givenHostedDraft_whenLockedThenUnlockedThroughSwiftUI_thenEditabilityFollowsInTheSameEditor() async throws {
        // given — the real representable with an editable draft.
        let fixture = try makeEditorWindowHost(DraftHost(text: "Retained draft", isLocked: false))
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return descendants(fixture.host).contains { ($0 as? ComposerPromptScrollView)?.promptTextView.string == "Retained draft" }
        }
        let prompt = try #require(descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first)
        let editor = prompt.promptTextView
        let identity = ObjectIdentifier(editor)

        // when — the SwiftUI update locks the exact same editor instance.
        (fixture.host as? NSHostingView<DraftHost>)?.rootView = DraftHost(text: editor.string, isLocked: true)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return !editor.isEditable
        }
        editor.insertText("x")

        // then — a locked native editor keeps its text and identity.
        #expect(!editor.isEditable)
        #expect(!editor.allowsUndo)
        #expect(editor.string == "Retained draft")
        #expect(ObjectIdentifier(editor) == identity)

        // when — the same update path unlocks again.
        (fixture.host as? NSHostingView<DraftHost>)?.rootView = DraftHost(text: editor.string, isLocked: false)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return editor.isEditable
        }

        // then
        #expect(editor.isEditable)
        #expect(ObjectIdentifier(editor) == identity)
    }

    @Test func givenHostedFocusedDraft_whenWidthChanges_thenEditorSelectionAndCaretSurvive() async throws {
        // given — a hosted editor with a mid-draft selection at a wide width.
        let fixture = try makeEditorWindowHost(DraftFillHost(text: "One two three"))
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return descendants(fixture.host).contains { ($0 as? ComposerPromptScrollView)?.promptTextView.string == "One two three" }
        }
        let prompt = try #require(descendants(fixture.host).compactMap { $0 as? ComposerPromptScrollView }.first)
        let editor = prompt.promptTextView
        let identity = ObjectIdentifier(editor)
        #expect(fixture.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 4, length: 3))

        // when — the viewport narrows: pure sizing, no view replacement or caret reset.
        fixture.window.setContentSize(NSSize(width: 220, height: 200))
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return editor.bounds.width < 300
        }
        await DisplayFrames.waitForPresentedFrame()

        // then — identity, selection and caret visibility survive the width change.
        #expect(ObjectIdentifier(editor) == identity)
        #expect(editor.selectedRange == NSRange(location: 4, length: 3))
        editor.scrollRangeToVisible(editor.selectedRange)
        let caret = try localCaret(of: editor.selectedRange, in: editor)
        let visible = editor.visibleRect
        #expect(caret.maxY <= visible.maxY + 1)
    }

    // MARK: - Hosted fixture

    @MainActor private final class HostedFixture {
        let window: NSWindow
        let host: NSView
        private let previousActivationPolicy: NSApplication.ActivationPolicy
        private let previousAccessibility: Any?
        private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

        init(window: NSWindow, host: NSView,
             previousActivationPolicy: NSApplication.ActivationPolicy,
             previousAccessibility: Any?) {
            self.window = window
            self.host = host
            self.previousActivationPolicy = previousActivationPolicy
            self.previousAccessibility = previousAccessibility
        }

        /// Closes only this fixture's own windows and restores the app-level state it borrowed.
        func dispose() {
            var disposed = Set<ObjectIdentifier>()
            func popups(of window: NSWindow) -> [NSWindow] {
                (window.childWindows ?? []).flatMap { [$0] + popups(of: $0) }
            }
            for popup in popups(of: window).reversed() where disposed.insert(ObjectIdentifier(popup)).inserted {
                popup.orderOut(nil)
                popup.close()
            }
            window.contentView = nil
            window.close()
            NSApp.setActivationPolicy(previousActivationPolicy)
            NSApplication.shared.accessibilitySetValue(previousAccessibility, forAttribute: enhanced)
        }
    }

    private func makeHostedFixture(
        model: NewSessionViewModelMock,
        size: NSSize,
        dark: Bool,
        optionsPresented: Bool = false
    ) throws -> HostedFixture {
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let controller = NSHostingController(
            rootView: NewSessionView(model, optionsPresented: optionsPresented)
                .preferredColorScheme(dark ? .dark : .light)
        )
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return HostedFixture(window: window, host: host,
                             previousActivationPolicy: previousActivationPolicy,
                             previousAccessibility: previousAccessibility)
    }

    /// Hosts the bare editor representable in a real window with the same app-state restoration.
    private func makeEditorWindowHost(_ root: some View) throws -> HostedFixture {
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 640, height: 300)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return HostedFixture(window: window, host: host,
                             previousActivationPolicy: previousActivationPolicy,
                             previousAccessibility: previousAccessibility)
    }

    /// `firstRect(forCharacterRange:)` reports the caret rect in screen coordinates; the
    /// comparison against the editor's own `visibleRect` needs the text view's local space.
    private func localCaret(of range: NSRange, in editor: NSTextView) throws -> NSRect {
        let window = try #require(editor.window)
        let screenRect = editor.firstRect(forCharacterRange: range, actualRange: nil)
        return editor.convert(window.convertFromScreen(screenRect), from: nil)
    }

    // MARK: - Established helpers

    private func activate(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 5) { NSApp.isActive && window.isKeyWindow }
        try #require(NSApp.isActive && window.isKeyWindow,
                     "Native focus/input/capture requires this fixture to be the active key window.")
    }

    private func sendKey(_ text: String, code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: text, charactersIgnoringModifiers: text,
                                                isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func optionFields(ownedBy owner: NSWindow) -> [NSTextField] {
        ownedPopovers(of: owner)
            .compactMap(\.contentView)
            .flatMap { descendants($0) }
            .compactMap { $0 as? NSTextField }
    }

    private func ownedPopovers(of owner: NSWindow) -> [NSWindow] {
        func collect(_ window: NSWindow) -> [NSWindow] {
            (window.childWindows ?? []).flatMap { [$0] + collect($0) }
        }
        return collect(owner).filter(\.isVisible)
    }

    private func contains(_ text: String, in window: NSWindow) -> Bool {
        tree(window).contains { matches($0, text) }
    }

    private func matches(_ object: NSObject, _ text: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == text
        }
    }

    private func accessibilityFrame(in window: NSWindow, text: String) -> NSRect? {
        guard let object = tree(window).first(where: { matches($0, text) }),
              object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }

    private func tree(_ root: NSObject) -> [NSObject] {
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

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_COMPOSER_CAPTURE_DIR"], !output.isEmpty else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func draft(passages: Int) -> String {
        (1 ... passages).map { "Passage \($0) of the fixture draft" }.joined(separator: "\n")
    }

    /// Draft passages that never wrap at the fixed editor hosting width.
    private func draftLines(_ lineCount: Int) -> String {
        (1 ... lineCount).map { "Draft line \($0) of the hosted editor fixture" }.joined(separator: "\n")
    }
}

// MARK: - DraftHost

/// A bare-editor host that drives the real representable only through its binding and updates.
@MainActor
private struct DraftHost: View {
    @State var text: String
    var isLocked = false

    var body: some View {
        ComposerPromptEditor(text: $text, isLocked: isLocked)
            .frame(width: 600)
    }
}

// MARK: - DraftFillHost

@MainActor
private struct DraftFillHost: View {
    @State var text: String

    var body: some View {
        ComposerPromptEditor(text: $text, isLocked: false)
    }
}
