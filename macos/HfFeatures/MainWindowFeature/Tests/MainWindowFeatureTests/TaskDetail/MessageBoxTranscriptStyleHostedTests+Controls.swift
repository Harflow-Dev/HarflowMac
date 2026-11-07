import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

// MARK: - MessageBoxTranscriptStyleHostedTests + controls

/// The send button, "Send now", the placeholder colour, the locked states and the disabled-reason mapping.
extension MessageBoxTranscriptStyleHostedTests {

    // MARK: Send button

    @Test(arguments: [false, true])
    func givenTranscriptComposer_whenEmptyThenFilled_thenSendIs32PointsAndItsFillMatchesTheDisabledAndEnabledTokens(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 600)
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, withSendNow: true, dark: dark), size: size, dark: dark)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        let send = try #require(page.element("Send"))
        await DisplayFrames.waitForPresentedFrame()
        let disabledToken = try await token(TaskScreenStyle.Composer.sendDisabledFill, dark: dark)
        let enabledToken = try await token(TaskScreenStyle.Composer.sendFill, dark: dark)
        let sendFrame = try #require(page.frame(send).map { page.host.convert($0, from: nil) })
        // A point inside the circle and clear of the arrow glyph.
        let probe = CGPoint(x: sendFrame.midX - 12, y: sendFrame.midY)

        // when
        let disabled = Shot(page.host).rgb(at: probe)
        let disabledGlyph = Shot(page.host).glyphCore(in: sendFrame.insetBy(dx: 7, dy: 7), fill: disabledToken)
        await Self.type("hello", into: field, in: page)
        let enabled = Shot(page.host).rgb(at: probe)
        let enabledGlyph = Shot(page.host).glyphCore(in: sendFrame.insetBy(dx: 7, dy: 7), fill: enabledToken)
        let disabledForeground = try await token(TaskScreenStyle.Composer.sendDisabledForeground, dark: dark)
        let enabledForeground = try await token(TaskScreenStyle.Composer.sendForeground, dark: dark)

        // then
        #expect(abs(sendFrame.width - 32) <= 0.5 && abs(sendFrame.height - 32) <= 0.5, "send button \(sendFrame.size)")
        #expect(Shot.close(disabled, disabledToken, 2), "disabled send pixel \(disabled), --surface-active \(disabledToken)")
        #expect(Shot.close(enabled, enabledToken, 2), "enabled send pixel \(enabled), --accent-solid \(enabledToken)")
        #expect(!Shot.close(disabled, enabled, 8), "enabled and disabled send fills are both \(enabled)")
        print("MB-GLYPH dark=\(dark) disabled=\(disabledGlyph) want=\(disabledForeground) enabled=\(enabledGlyph) want=\(enabledForeground)")
        #expect(Shot.close(disabledGlyph, disabledForeground, 14), "disabled arrow \(disabledGlyph), --text-tertiary \(disabledForeground)")
        #expect(Shot.close(enabledGlyph, enabledForeground, 14), "enabled arrow \(enabledGlyph), --on-accent \(enabledForeground)")
    }

    @Test(arguments: [MessageBoxStyle.standard, .transcript])
    func givenEitherStyle_whenSendIsInspected_thenItsLabelTooltipAndShortcutAreTheSame(style: MessageBoxStyle) async throws {
        // given
        let sink = SubmitSink()
        let page = fixture(Self.composerStack(Self.enabledModel, style: style, sink: sink, dark: false),
                           size: CGSize(width: 1400, height: 600), dark: false)
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { page.window.isKeyWindow && Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        let send = try #require(page.element("Send"))

        // when
        await Self.type("  queued message ", into: field, in: page)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: page.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        let handled = page.window.performKeyEquivalent(with: event)
        await page.settle { !sink.values.isEmpty }

        // then
        #expect(page.string(send, "accessibilityLabel") == "Send")
        #expect(page.string(send, "accessibilityHelp") == "Send (⌘↩)", "tooltip \(String(describing: page.string(send, "accessibilityHelp")))")
        #expect(handled)
        #expect(sink.values == ["  queued message "])
    }

    @Test func givenTranscriptComposerWithSendNow_whenMeasured_thenSendNowSitsSixPointsBeforeSendAndInOneRow() async throws {
        // given
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, withSendNow: true, dark: false),
                           size: CGSize(width: 1400, height: 600), dark: false)
        defer { page.close() }
        await page.settle { page.element("Send now") != nil && page.element("Send") != nil }
        await DisplayFrames.waitForPresentedFrame()

        // when
        let sendNow = ComposerMeasure.frame("Send now", in: page)
        let send = ComposerMeasure.frame("Send", in: page)
        let field = try #require(Self.editableField(in: page)).convert(try #require(Self.editableField(in: page)).bounds, to: page.host)

        // then
        #expect(abs((send.minX - sendNow.maxX) - TaskScreenStyle.Composer.barGap) <= 1.5, "gap \(send.minX - sendNow.maxX)")
        #expect(abs(sendNow.midY - send.midY) <= 1.5 && abs(field.midY - send.midY) <= 1.5,
                "rows: field \(field.midY) send now \(sendNow.midY) send \(send.midY)")
        #expect(field.maxX <= sendNow.minX + 1)
    }

    // MARK: Placeholder

    @Test(arguments: [false, true])
    func givenEmptyTranscriptField_whenRendered_thenThePlaceholderInkIsTheTertiaryTokenNotTheInputColour(dark: Bool) async throws {
        // given
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, dark: dark),
                           size: CGSize(width: 1400, height: 600), dark: dark)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        await DisplayFrames.waitForPresentedFrame()
        var passes = 0
        await page.settle { passes += 1; return passes >= 10 }
        let surface = try await token(TaskScreenStyle.Composer.fill, dark: dark)
        let tertiary = try await token(TaskScreenStyle.Colors.textTertiary, dark: dark)
        let input = try await token(TaskScreenStyle.Composer.inputColor, dark: dark)
        let field = try #require(Self.editableField(in: page))
        let frame = field.convert(field.bounds, to: page.host)

        // when — the pixel furthest from the surface inside the field is the glyph core.
        let shot = Shot(page.host)
        var core = surface
        for y in Int(frame.minY * shot.scale) ..< Int(frame.maxY * shot.scale) {
            for x in Int(frame.minX * shot.scale) ..< Int((frame.minX + 160) * shot.scale) {
                let pixel = shot.rgb(px: x, y)
                if Shot.distance(pixel, surface) > Shot.distance(core, surface) { core = pixel }
            }
        }
        print("MB-PLACEHOLDER dark=\(dark) core=\(core) tertiary=\(tertiary) input=\(input) surface=\(surface)")

        // then — the overlay draws in --text-tertiary (the glyph core can only be lighter than the true ink).
        #expect(Shot.close(core, tertiary, 14), "placeholder core \(core), --text-tertiary \(tertiary)")
        #expect(Shot.distance(core, tertiary) < Shot.distance(core, input), "placeholder core \(core) is nearer --text \(input)")
    }

    @Test(arguments: [false, true])
    func givenPlaceholderAndTypedText_whenTheSameStringIsMeasured_thenLeadingEdgeAndFirstLineTopAgreeWithinOnePoint(dark: Bool) async throws {
        // given
        let placeholder = Self.enabledModel.placeholder
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, dark: dark),
                           size: CGSize(width: 1400, height: 600), dark: dark)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        let surface = try await token(TaskScreenStyle.Composer.fill, dark: dark)
        await DisplayFrames.waitForPresentedFrame()
        var passes = 0
        await page.settle { passes += 1; return passes >= 10 }
        let frame = field.convert(field.bounds, to: page.host)

        // when
        let asPlaceholder = try #require(Shot(page.host).inkBox(in: frame, surface: surface), "no placeholder ink")
        await Self.type(placeholder, into: field, in: page)
        _ = page.window.makeFirstResponder(nil)
        await page.settle { Self.editableField(in: page)?.currentEditor() == nil }
        let asTyped = try #require(Shot(page.host).inkBox(in: frame, surface: surface), "no typed ink")
        print("MB-OVERLAY dark=\(dark) placeholder=\(asPlaceholder) typed=\(asTyped)")

        // then
        #expect(abs(asPlaceholder.minX - asTyped.minX) <= 1, "leading ink edge: placeholder \(asPlaceholder.minX), typed \(asTyped.minX)")
        #expect(abs(asPlaceholder.minY - asTyped.minY) <= 1, "first-line glyph top: placeholder \(asPlaceholder.minY), typed \(asTyped.minY)")
    }

    @Test func givenPlaceholder_whenTextIsTypedAndCleared_thenItDisappearsAndReturns() async throws {
        // given
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, dark: false),
                           size: CGSize(width: 1400, height: 600), dark: false)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        let surface = try await token(TaskScreenStyle.Composer.fill, dark: false)
        await DisplayFrames.waitForPresentedFrame()
        let frame = field.convert(field.bounds, to: page.host)
        func ink() -> CGRect? { Shot(page.host).inkBox(in: frame, surface: surface) }
        let initial = try #require(ink())

        // when
        await Self.type(".", into: field, in: page)
        _ = page.window.makeFirstResponder(nil)
        let typed = ink()
        await Self.type("", into: field, in: page)
        _ = page.window.makeFirstResponder(nil)
        let cleared = try #require(ink(), "the placeholder did not return")

        // then — one full stop is far narrower than the placeholder, and nothing of the placeholder remains.
        #expect(initial.width > 80, "placeholder ink \(initial)")
        #expect((typed?.width ?? 0) < 12, "ink with text present \(String(describing: typed))")
        #expect(abs(cleared.minX - initial.minX) <= 1 && abs(cleared.width - initial.width) <= 1, "returned \(cleared), was \(initial)")
    }

    @Test func givenPlaceholder_whenItIsHitTestedAndFocused_thenTheFieldReceivesItAndTypingSubmits() async throws {
        // given — a synthetic mouseDown enters AppKit's tracking loop and blocks the hosted run, so the click is
        // reduced to its two observable halves: what a click at the placeholder hits, and focus plus typing.
        let sink = SubmitSink()
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, sink: sink, dark: false),
                           size: CGSize(width: 1400, height: 600), dark: false)
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { page.window.isKeyWindow && Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        let frame = field.convert(field.bounds, to: page.host)
        let overPlaceholder = CGPoint(x: frame.minX + 24, y: frame.midY)

        // when
        let hit = page.host.hitTest(page.host.superview.map { page.host.convert(overPlaceholder, to: $0) } ?? overPlaceholder)
        var owner: NSView? = hit
        while let view = owner, view !== field { owner = view.superview }
        _ = page.window.makeFirstResponder(owner ?? field)
        await page.settle { field.currentEditor() != nil }
        let editor = field.currentEditor() as? NSTextView
        editor?.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        await Self.type("abc", into: field, in: page)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: page.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        _ = page.window.performKeyEquivalent(with: event)
        await page.settle { !sink.values.isEmpty }

        // then
        #expect(owner === field, "a click over the placeholder hits \(String(describing: hit)), not the text field")
        #expect(editor != nil, "the field has no editor after taking focus")
        #expect(sink.values == ["abc"], "submitted \(sink.values)")
    }

    @Test func givenEnabledTranscriptComposer_whenAccessibilityIsRead_thenOnlyOneElementCarriesThePlaceholderLabel() async throws {
        let style = MessageBoxStyle.transcript
        // given
        let placeholder = Self.enabledModel.placeholder
        let page = fixture(Self.composerStack(Self.enabledModel, style: style, dark: false),
                           size: CGSize(width: 1400, height: 600), dark: false)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil && page.element(placeholder) != nil }
        let field = try #require(Self.editableField(in: page))

        // when — every accessibility element reachable from the hosted views, each once.
        var seen = Set<ObjectIdentifier>()
        let everything = page.descendants.flatMap { page.elements(in: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let labelled = everything.filter { page.string($0, "accessibilityLabel") == placeholder }
        let described = labelled.map { "\(Swift.type(of: $0)) role=\(page.string($0, "accessibilityRole") ?? "-")" }
        print("MB-AX style=\(style) labelled=\(described) fieldLabel=\(String(describing: field.accessibilityLabel()))")

        // then — the one AXTextField carries the placeholder as its label; no static text does (the overlay `Text` is
        // hidden). SwiftUI's own wrapper views (`AppKitTextField`, the scroll-chrome markers) repeat the label as
        // non-text nodes, so the count of labelled elements overall is not meaningful and is not asserted.
        let textFields = labelled.filter { page.string($0, "accessibilityRole") == "AXTextField" }
        let staticTexts = everything.filter {
            page.string($0, "accessibilityRole") == "AXStaticText"
                && [page.string($0, "accessibilityLabel"), page.string($0, "accessibilityValue")].contains(placeholder)
        }
        #expect(textFields.count == 1, "\(textFields.count) text fields labelled \"\(placeholder)\": \(described)")
        #expect(field.accessibilityLabel() == placeholder)
        #expect(staticTexts.isEmpty, "the overlay is exposed as \(staticTexts.count) static text element(s)")
        #expect(everything.filter { page.string($0, "accessibilityValue") == placeholder }.isEmpty,
                "the placeholder is also exposed as a value, so it would be read twice")
    }

    // MARK: Locked

    @Test(arguments: [MessageBoxStyle.standard, .transcript])
    func givenLockedModel_whenHosted_thenBothStylesShowTheSameTextAndNoEditableField(style: MessageBoxStyle) async throws {
        // given / when
        let page = fixture(Self.composerStack(Self.lockedModel, style: style, dark: false), size: CGSize(width: 1400, height: 600), dark: false)
        defer { page.close() }
        await page.settle { page.element(MessageBoxDisabledReason.takenOver.text) != nil }
        let label = try #require(page.element(MessageBoxDisabledReason.takenOver.text))

        // then
        #expect(Self.editableField(in: page) == nil, "a locked composer must not host a text field")
        #expect(page.matches(label, MessageBoxDisabledReason.takenOver.text))
        #expect(page.element("Send now") == nil)
    }

    @Test(arguments: [MessageBoxStyle.standard, .transcript], [true, false])
    func givenModel_whenItsBodyIsReflected_thenTheLockIconShowsOnlyForALockedModelInBothStyles(style: MessageBoxStyle, locked: Bool) {
        // given
        let model = locked ? Self.lockedModel : Self.enabledModel
        let view = MessageBoxView(model: model, style: style) { _ in true }

        // when
        let strings = Self.strings(in: view.body)

        // then
        #expect(strings.contains("lock.fill") == locked, "\(style) locked=\(locked): \(strings.filter { $0.contains("lock") })")
        #expect(strings.contains(model.placeholder))
    }

    @Test func givenDisabledReasons_whenMapped_thenTextLockAndTaskPrecedenceAreUnchanged() throws {
        // given / when / then
        #expect(MessageBoxDisabledReason.notLiveInput.text == "Messages are off — this task wasn't started with live input")
        #expect(MessageBoxDisabledReason.takenOver.text == "Messages are off — you took this task over in Terminal")
        #expect(MessageBoxDisabledReason.noSession.text == "This task has no session to continue.")
        #expect(MessageBoxDisabledReason.other.text == "Messages are unavailable right now.")
        func task(_ status: String, takenOver: Bool, liveInput: Bool) throws -> TaskInfo {
            try #require(TaskInfo(.object([
                "task_id": .string("t"), "backend": .string("claude"), "status": .string(status),
                "taken_over": .bool(takenOver), "live_input": .bool(liveInput)
            ])))
        }
        #expect(MessageBoxDisabledReason.reason(for: try task("running", takenOver: true, liveInput: true)) == .takenOver)
        #expect(MessageBoxDisabledReason.reason(for: try task("running", takenOver: true, liveInput: false)) == .takenOver)
        #expect(MessageBoxDisabledReason.reason(for: try task("running", takenOver: false, liveInput: false)) == .notLiveInput)
        #expect(MessageBoxDisabledReason.reason(for: try task("running", takenOver: false, liveInput: true)) == .other)
        #expect(MessageBoxDisabledReason.reason(for: try task("completed", takenOver: false, liveInput: true)) == .noSession)
        #expect(MessageBoxModel.disabled.placeholder == MessageBoxDisabledReason.noSession.text)
    }

    // MARK: Reflection

    /// Every `String` stored anywhere in a (reflected) view value, for finding a symbol name or a literal.
    static func strings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value, depth: depth + 1) }
    }
}

extension Shot {
    static func distance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}

extension Shot {
    /// The pixel in `rect` furthest from `fill`: the core of a glyph drawn on it.
    func glyphCore(in rect: CGRect, fill: [Int]) -> [Int] {
        var core = fill
        for y in Int(rect.minY * scale) ..< Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale) ..< Int(rect.maxX * scale) {
                let pixel = rgb(px: x, y)
                if Self.distance(pixel, fill) > Self.distance(core, fill) { core = pixel }
            }
        }
        return core
    }

    /// The bounds of everything in `frame` (widened 4 pt vertically) clearly different from `surface`.
    func inkBox(in frame: CGRect, surface: [Int]) -> CGRect? {
        var minX = Int.max
        var maxX = -1
        var minY = Int.max
        var maxY = -1
        for y in Int((frame.minY - 4) * scale) ..< Int((frame.maxY + 4) * scale) {
            for x in Int(frame.minX * scale) ..< Int(frame.maxX * scale) where Self.distance(rgb(px: x, y), surface) > 60 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
