import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct NewSessionComposerHostedTests {
    @Test(arguments: [false, true])
    func givenComposer_whenHostedAtApprovedSizes_thenDraftAndNativeEditorRemainAvailable(dark: Bool) async throws {
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
            // given
            _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
            let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Retain this exact draft")
            model.model = "custom-model"
            model.effort = "unsupported-effort"
            model.turnLimit = "not-a-number"
            model.validationMessages = ["Review the requested turn limit."]
            let root = NewSessionView(model).preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { dispose(window) }
        try await activate(window)

            // when
            await waitUntil(timeout: 5) {
                host.layoutSubtreeIfNeeded()
                return descendants(host).contains { ($0 as? NSTextView)?.string == model.message }
            }
            let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == model.message })

            // then
            #expect(editor.isEditable)
            #expect(editor.bounds.width <= 720)
            #expect(model.message == "Retain this exact draft")
            #expect(model.model == "custom-model")
            #expect(model.effort == "unsupported-effort")
            #expect(model.turnLimit == "not-a-number")
            try capture(host, name: "composer-\(Int(size.width))-\(dark ? "dark" : "light")")
        }
    }

    @Test(arguments: [ComposerState.submitting, .unknown, .created])
    func givenLockedOutcome_whenHosted_thenPromptCannotBeEdited(state: ComposerState) async throws {
        // given
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Submitted draft")
        model.composerState = state
        model.isStarting = state == .submitting
        let host = NSHostingView(rootView: NewSessionView(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { dispose(window) }
        try await activate(window)

        // when
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).contains { ($0 as? NSTextView)?.string == model.message }
        }
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == model.message })

        // then
        #expect(!editor.isEditable)
        #expect(model.message == "Submitted draft")
        #expect(model.canReviewRecent == (state == .unknown))
        #expect(!accessibilityTree(host).contains { matches($0, text: "Starting task…") })
        #expect(!descendants(host).contains { $0 is NSProgressIndicator })
    }

    @Test func givenUnsupportedRequestedOptions_whenPopoverOpens_thenValuesRemainEditableAndScrollable() async throws {
        // given
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let model = NewSessionViewModelMock(backend: "vibe", repo: "/fixture/repository", message: "Fixture draft", controls: .previewVibeLike)
        model.effort = "retained-effort"
        model.turnLimit = "retained-invalid-turns"
        let host = NSHostingView(rootView: NewSessionView(model, optionsPresented: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { dispose(window) }
        try await activate(window)

        // when
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return optionFields(ownedBy: window).contains { $0.stringValue == "retained-effort" }
        }
        let fields = optionFields(ownedBy: window)
        let effort = try #require(fields.first { $0.stringValue == "retained-effort" })
        let turns = try #require(fields.first { $0.stringValue == "retained-invalid-turns" })

        // then
        #expect(effort.isEditable)
        #expect(turns.isEditable)
        #expect(!model.showsEffort)
        #expect(model.effort == "retained-effort")
        for candidate in ownedPopovers(of: window) {
            if let content = candidate.contentView, content !== host {
                try capture(content, name: "composer-options-minimum")
                // The popover inherits the system scroller style (nothing forces overlay there), so this checks
                // only that the options stay in a scroll view; it no longer assumes the overlay setting.
                let scrolls = descendants(content).compactMap { $0 as? NSScrollView }
                let systemStyle = NSScroller.preferredScrollerStyle
                #expect(!scrolls.isEmpty)
                #expect(scrolls.contains { $0.scrollerStyle == systemStyle })
            }
        }
    }

    @Test(arguments: [HarnessQualificationModel.State.checking, .unavailable])
    func givenUnqualifiedDraft_whenOptionsAreClosed_thenCachedQualificationIsVisible(state: HarnessQualificationModel.State) async throws {
        // given
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous, forAttribute: enhanced) }
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Valid draft")
        model.qualificationCards = [.init(id: "fixture", model: .init(
            identity: "Fixture harness", state: state, message: "Fixture qualification evidence", features: []))]
        let controller = NSHostingController(rootView: NewSessionView(model))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { dispose(window) }
        try await activate(window)
        let expected = "Harness qualification: \(state.title). Fixture qualification evidence"

        // when
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return accessibilityTree(window).contains { matches($0, text: expected) }
        }

        // then
        #expect(!model.canStart)
        #expect(accessibilityTree(window).contains { matches($0, text: expected) })
        #expect(!optionFields(ownedBy: window).contains { $0.placeholderString == "Optional task title" })
    }

    @Test func givenUnknownOutcome_whenClosedOptionsAreOpened_thenRetainedChoicesAreReadOnly() async throws {
        // given
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous, forAttribute: enhanced) }
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Submitted draft")
        model.name = "Exact submitted title"
        model.effort = "exact-retained-effort"
        model.turnLimit = "17"
        model.callerApprovals = true
        model.composerState = .unknown
        let controller = NSHostingController(rootView: NewSessionView(model))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { dispose(window) }
        try await activate(window)
        let press = NSSelectorFromString("accessibilityPerformPress")

        // when
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return accessibilityTree(window).contains { matches($0, text: "More task options") && $0.responds(to: press) }
        }
        let button = try #require(accessibilityTree(window).first { matches($0, text: "More task options") && $0.responds(to: press) })
        _ = button.perform(press)
        await waitUntil(timeout: 5) { optionFields(ownedBy: window).contains { $0.stringValue == model.name } }
        let fields = optionFields(ownedBy: window)
        let title = try #require(fields.first { $0.stringValue == model.name })
        let effort = try #require(fields.first { $0.stringValue == model.effort })

        // then
        #expect(!title.isEnabled)
        #expect(!effort.isEnabled)
        #expect(model.name == "Exact submitted title")
        #expect(model.effort == "exact-retained-effort")
        #expect(model.turnLimit == "17")
        #expect(model.callerApprovals)
        try await assertRetainedCallerApprovals(in: window)
    }

    private func assertRetainedCallerApprovals(in window: NSWindow) async throws {
        try dumpOwnedAccessibility(window, name: "unknown-retained-options-before-scroll")
        let popups = ownedPopovers(of: window)
        let nativeButtons = popups.compactMap(\.contentView)
.flatMap { descendants($0) }
            .compactMap { $0 as? NSButton }
.filter { !($0 is NSPopUpButton) }
        let checked = nativeButtons.filter { $0.cell?.state == .on }
        let checkbox = try #require(checked.count == 1 ? checked.first : nil,
                                   "The owned options popup must retain exactly one checked native caller-approval checkbox.")
        checkbox.scrollToVisible(checkbox.bounds)
        await DisplayFrames.waitForPresentedFrame()
        try dumpOwnedAccessibility(window, name: "unknown-retained-options")
        let toggle = ownedPopovers(of: window)
.flatMap { accessibilityTree($0) }
            .first { matches($0, text: "Caller approvals") }
        let nativeEvidence = "native state=\(checkbox.state.rawValue), cell state=\(String(describing: checkbox.cell?.state.rawValue)), "
            + "enabled=\(checkbox.isEnabled), label exposed=\(toggle != nil)"
        try writeDiagnostic(nativeEvidence, name: "unknown-retained-checkbox")
        // Public AX roots and the backing native checkbox are separate SwiftUI representations.
        // The exact checked/disabled contract is asserted against the actual owned native control.
        #expect(checkbox.state == .on)
        #expect(checkbox.cell?.state == .on)
        #expect(!checkbox.isEnabled)
        let labeled = try #require(toggle,
                                   "The visible caller-approval checkbox must expose its required public accessibility label.")
        let valueSelector = NSSelectorFromString("accessibilityValue")
        let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
        try #require(labeled.responds(to: valueSelector) && labeled.responds(to: enabledSelector))
        let value = labeled.perform(valueSelector)?.takeUnretainedValue() as? NSNumber
        #expect(value?.boolValue == true)
        #expect(labeled.value(forKey: "accessibilityEnabled") as? Bool == false)
    }

    @Test func givenUnrelatedAndHiddenOwnedWindows_whenOptionsAreClosed_thenQueriesAndTeardownStayOwned() async throws {
        // given
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let host = NSHostingView(rootView: NewSessionView(NewSessionViewModelMock()))
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.contentView = host
        owner.orderFront(nil)
        try await activate(owner)
        let unrelated = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        let unrelatedField = NSTextField(string: "unrelated-retained-effort")
        unrelatedField.placeholderString = "Optional task title"
        unrelated.contentView = unrelatedField
        unrelated.orderFront(nil)
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        let hiddenField = NSTextField(string: "hidden-retained-effort")
        hiddenField.placeholderString = "Optional task title"
        let hiddenContent = NSView(frame: hidden.contentLayoutRect)
        hiddenContent.addSubview(hiddenField)
        hidden.contentView = hiddenContent
        owner.addChildWindow(hidden, ordered: .above)
        hidden.orderOut(nil)
        let explicitlyOwnedWindows = [hidden]
        defer { dispose(owner, explicitlyOwned: explicitlyOwnedWindows); unrelated.close() }

        // when
        let fields = optionFields(ownedBy: owner)

        // then — neither a visible unrelated window nor an owned but hidden historical popup
        // can satisfy the closed-options absence assertion. Teardown touches only our owner.
        #expect(fields.isEmpty)
        #expect(!fields.contains { $0.placeholderString == "Optional task title" })
        #expect(ownedPopovers(of: owner).isEmpty)
        #expect(!hidden.isVisible)
        #expect(hidden.contentView === hiddenContent)
        #expect(explicitlyOwnedWindows.contains { $0 === hidden })
        dispose(owner, explicitlyOwned: explicitlyOwnedWindows)
        #expect(!hidden.isVisible)
        #expect(unrelated.isVisible)
        #expect(unrelated.contentView === unrelatedField)
    }

    @Test(arguments: [ComposerState.submitting, .unknown])
    func givenFocusedEditablePrompt_whenOutcomeLocks_thenTargetedInputCannotChangeNativeOrModelText(state: ComposerState) async throws {
        // given — prove the real native input path changes this observable fixture while editable.
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Editable positive control")
        let controller = NSHostingController(rootView: NewSessionView(model))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { dispose(window) }
        try await activate(window)
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).contains { ($0 as? NSTextView)?.string == model.message }
        }
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == model.message })
        #expect(editor.isEditable)
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        await waitUntil(timeout: 5) { window.isKeyWindow && window.firstResponder === editor }
        try #require(window.isKeyWindow && window.firstResponder === editor)
        try sendKey("x", code: 7, to: window)
        await waitUntil(timeout: 5) { model.message == "Editable positive controlx" && editor.string == model.message }
        try #require(model.message == "Editable positive controlx" && editor.string == model.message,
                     "The editable positive control must update both native and model text before the lock probe is valid.")
        try #require(window.isKeyWindow && window.firstResponder === editor,
                     "The same native editor must still own key focus immediately before locking.")
        let submittedText = model.message
        let before = describeEditor(editor, window: window, model: model)

        // when — retain the exact editor instance that owned focus at the submission boundary.
        model.composerState = state
        await DisplayFrames.waitForPresentedFrame()
        host.layoutSubtreeIfNeeded()
        let locked = describeEditor(editor, window: window, model: model)
        try sendKey("z", code: 6, to: window)
        await DisplayFrames.waitForPresentedFrame()
        host.layoutSubtreeIfNeeded()
        let after = "editable=\(editor.isEditable), AXEnabled=\(editor.isAccessibilityEnabled()), native=\(editor.string), model=\(model.message)"
        try writeDiagnostic("before: \(before)\nlocked: \(locked)\nafter input: \(after)", name: "focused-editor-lock-\(String(describing: state))")

        // then — keep the strict native assertion while collecting evidence of actual input.
        #expect(!editor.isEditable)
        #expect(editor.string == submittedText)
        #expect(model.message == submittedText)
    }

    private func activate(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 5) { NSApp.isActive && window.isKeyWindow }
        try #require(NSApp.isActive && window.isKeyWindow,
                     "Native focus/input/capture requires this fixture to be the active key window.")
    }

    private func describeEditor(_ editor: NSTextView, window: NSWindow, model: NewSessionViewModelMock) -> String {
        "editable=\(editor.isEditable), AXEnabled=\(editor.isAccessibilityEnabled()), key=\(window.isKeyWindow), "
            + "focused=\(window.firstResponder === editor), native=\(editor.string), model=\(model.message)"
    }

    private func sendKey(_ text: String, code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: text, charactersIgnoringModifiers: text,
                                                isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func accessibilityTree(_ root: NSObject) -> [NSObject] {
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

    private func matches(_ object: NSObject, text: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == text
        }
    }

    // A popup is owned only when AppKit attaches it to this exact fixture window. Merely
    // appearing later in NSApp.windows is not ownership, and hidden historical popovers are
    // never queried as currently presented content.
    private func ownedPopovers(of owner: NSWindow, visibleOnly: Bool = true) -> [NSWindow] {
        func collect(_ window: NSWindow) -> [NSWindow] {
            (window.childWindows ?? []).flatMap { [$0] + collect($0) }
        }
        return collect(owner).filter { !visibleOnly || $0.isVisible }
    }

    private func dispose(_ owner: NSWindow, explicitlyOwned: [NSWindow] = []) {
        var disposed = Set<ObjectIdentifier>()
        let popups = ownedPopovers(of: owner, visibleOnly: false) + explicitlyOwned
        for popup in popups.reversed() where disposed.insert(ObjectIdentifier(popup)).inserted {
            popup.orderOut(nil)
            popup.close()
        }
        owner.contentView = nil
        owner.close()
    }

    private func optionFields(ownedBy owner: NSWindow) -> [NSTextField] {
        ownedPopovers(of: owner)
.compactMap(\.contentView)
            .flatMap { descendants($0) }
.compactMap { $0 as? NSTextField }
    }

    private func dumpOwnedAccessibility(_ owner: NSWindow, name: String) throws {
        let rows = ownedPopovers(of: owner).flatMap { popup in
            accessibilityTree(popup).map { object in
                let strings = ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                    .map { key -> String in
                        let selector = NSSelectorFromString(key)
                        guard object.responds(to: selector) else { return "\(key)=<absent>" }
                        let value = object.perform(selector)?.takeUnretainedValue()
                        return "\(key)=\(String(describing: value))"
                    }
                let enabled = (object as? any NSAccessibilityProtocol)?.isAccessibilityEnabled()
                let native = (object as? NSButton).map {
                    " nativeState=\($0.state.rawValue) enabled=\($0.isEnabled) cellState=\(String(describing: $0.cell?.state.rawValue))"
                } ?? ""
                return "\(type(of: object)) AXEnabled=\(String(describing: enabled))\(native) " + strings.joined(separator: " | ")
            }
        }
        try writeDiagnostic(rows.joined(separator: "\n"), name: name)
    }

    private func writeDiagnostic(_ text: String, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_COMPOSER_DIAGNOSTICS_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_COMPOSER_CAPTURE_DIR"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
