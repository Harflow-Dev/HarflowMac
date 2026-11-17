import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - NeedsYouQuestionCardHostedTests

/// Guarded in-memory real-VM fixtures. Evidence captures only the owned window.
@MainActor @Suite(.serialized) struct NeedsYouQuestionCardHostedTests {
    enum State: String, CaseIterable {
        case text, offered, answered, unavailable
    }

    enum Layout: CaseIterable {
        case light, dark, minimumLight, minimumDark
        var dark: Bool { self == .dark || self == .minimumDark }
        var minimum: Bool { self == .minimumLight || self == .minimumDark }
    }

    @Test(arguments: State.allCases, Layout.allCases)
    func givenWorkflowQuestionState_whenListMounted_thenCardIsAccessibleAndCaptured(state: State, layout: Layout) async throws {
        let dark = layout.dark
        let minimum = layout.minimum
        // given
        let fixture = QuestionCardHostedFixture(offered: state == .offered)
        let page = mount(fixture, dark: dark, minimum: minimum)
        defer { fixture.vm.didDisappear(); page.close() }
        await ready(page, fixture)
        let card = try #require(fixture.vm.presentation.questions.first)
        if state == .answered || state == .unavailable { fixture.vm.setQuestionDraft("Check production first", for: card) }
        // when
        if state == .answered {
            fixture.useCase.answerOutcome = .alreadyAnswered(answer: "Use staging", answeredBy: .caller, answeredAt: 1794817800)
            fixture.vm.submitQuestion(card, offered: nil)
            await page.settle { page.element("Already answered by the caller") != nil }
        } else if state == .unavailable {
            fixture.useCase.subject.send(.init(phase: .ready, items: [], unreadableSourceCount: 1, withdrawn: [card.item]))
            await page.settle { page.element("Try again") != nil }
        }
        // then
        try #require(page.element(QuestionCardHostedFixture.question) != nil)
        try #require(page.element("Open run") != nil)
        switch state {
        case .text:
            let send = try #require(page.element("Send answer"))
            let enabled = try #require(Self.isEnabled(send))
            #expect(!enabled)
        case .offered:
            #expect(page.element("retry") != nil && page.element("switch") != nil)
            #expect(page.element("Your answer") == nil)
        case .answered:
            #expect(page.element("Your saved draft") != nil)
            #expect(page.element("Use staging") != nil)
            #expect(page.element("Send answer") == nil)
        case .unavailable:
            let send = try #require(page.element("Send answer"))
            let enabled = try #require(Self.isEnabled(send))
            #expect(!enabled)
            let refreshes = fixture.useCase.refreshCalls
            #expect(page.press(try #require(page.element("Try again"))))
            #expect(fixture.useCase.refreshCalls == refreshes + 1)
            #expect(fixture.vm.questionDraft(for: card) == "Check production first")
        }
        await DisplayFrames.waitForPresentedFrame()
        try await capture(page, name: "\(state.rawValue)-\(dark ? "dark" : "light")-\(minimum ? "1000x620" : "1280x800")")
    }

    @Test func givenFocusedAnswer_whenCommandReturnPressed_thenExactQuestionIsSentOnceAndFocusRemainsInCard() async throws {
        // given
        let fixture = QuestionCardHostedFixture()
        fixture.useCase.holdAnswers = true
        let page = mount(fixture)
        defer { fixture.useCase.completeAnswer(.accepted); fixture.vm.didDisappear(); page.close() }
        await ready(page, fixture)
        let card = try #require(fixture.vm.presentation.questions.first)
        let editor = try #require(page.descendants.compactMap { $0 as? NSTextView }.first { $0.isEditable })
        #expect(page.window.makeFirstResponder(editor))
        editor.insertText("Use staging", replacementRange: NSRange(location: NSNotFound, length: 0))
        await page.settle { fixture.vm.questionDraft(for: card) == "Use staging" && page.element("Send answer") != nil }
        // when
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                windowNumber: page.window.windowNumber, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        page.window.performKeyEquivalent(with: event)
        await page.settle { fixture.useCase.answerCalls == 1 }
        // then
        #expect(fixture.useCase.answerCalls == 1)
        #expect(fixture.useCase.answers.first?.0 == card.item)
        #expect(fixture.useCase.answers.first?.1 == "Use staging")
        #expect(fixture.routing.selections.isEmpty)
        #expect(page.window.firstResponder === editor)
    }

    @Test func givenOfferedQuestion_whenOfferedControlActivated_thenOnlyItsExactTokenIsSent() async throws {
        // given
        let fixture = QuestionCardHostedFixture(offered: true)
        let page = mount(fixture)
        defer { fixture.vm.didDisappear(); page.close() }
        await ready(page, fixture)
        // when
        #expect(page.press(try #require(page.element("switch"))))
        await page.settle { fixture.useCase.answerCalls == 1 }
        // then
        #expect(fixture.useCase.answers.first?.1 == "switch")
        #expect(page.element("Your answer") == nil)
    }

    @Test(arguments: [false, true])
    func givenLongQuestionWithReduceMotion_whenMinimumPaneMounted_thenTextAndActionsStayInsideScrollablePane(dark: Bool) async throws {
        // given
        let text = String(repeating: "A long workflow question has readable prose and keeps its complete answer controls. ", count: 40)
        let fixture = QuestionCardHostedFixture(text: text)
        let page = mount(fixture, dark: dark, minimum: true)
        defer { fixture.vm.didDisappear(); page.close() }
        await ready(page, fixture, question: text)
        // when
        let open = try #require(page.element("Open run"))
        let frame = try #require(page.frame(open))
        // then — vertical overflow is intentional; horizontal overflow is not.
        #expect(frame.minX >= 0 && frame.maxX <= page.host.bounds.width + 1)
        #expect(fixture.vm.presentation.questions.first?.detail.text == text)
        #expect(page.descendants.contains { $0 is NSScrollView })
        #expect(page.press(open))
        #expect(fixture.routing.runs == ["fixture-run"])
        try await capture(page, name: "long-minimum-reduce-motion-\(dark ? "dark" : "light")")
    }

    @Test func givenQuestionAInFlight_whenBIsBeingEditedAndACompletes_thenKeyboardAndAccessibilityFocusStayOnB() async throws {
        // given
        let fixture = QuestionCardHostedFixture()
        let firstItem = try #require(fixture.useCase.snapshot.items.first)
        var secondItem = firstItem
        secondItem.id = "input:fixture-run:second-question"
        secondItem.decisionID = "second-question"
        secondItem.text = "Second question"
        fixture.useCase.subject.send(.init(phase: .ready, items: [firstItem, secondItem]))
        fixture.useCase.holdAnswers = true
        let page = mount(fixture)
        defer { fixture.useCase.completeAnswer(.accepted); fixture.vm.didDisappear(); page.close() }
        await page.settle { fixture.vm.presentation.questions.count == 2 && page.descendants.compactMap { $0 as? NSTextView }.filter(\.isEditable).count == 2 }
        let first = try #require(fixture.vm.questions.first)
        fixture.vm.setQuestionDraft("A answer", for: first)
        fixture.vm.submitQuestion(first, offered: nil)
        await page.settle { fixture.useCase.answerCalls == 1 }
        let editors = page.descendants.compactMap { $0 as? NSTextView }
        let secondEditor = try #require(editors.last { $0.isEditable })
        #expect(page.window.makeFirstResponder(secondEditor))
        secondEditor.insertText("B draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        await page.settle { fixture.vm.questions.last?.draft == "B draft" }
        let focused = (page.window.accessibilityAttributeValue(.focusedUIElement) as? NSObject)
            ?? (NSApp.accessibilityAttributeValue(.focusedUIElement) as? NSObject)
        let before = try #require(focused)
        // when
        fixture.useCase.completeAnswer(.alreadyAnswered(answer: "A winner", answeredBy: .caller, answeredAt: 1793059200))
        await page.settle { page.element("Already answered by the caller") != nil }
        await DisplayFrames.waitForPresentedFrame()
        // then
        let after = (page.window.accessibilityAttributeValue(.focusedUIElement) as? NSObject)
            ?? (NSApp.accessibilityAttributeValue(.focusedUIElement) as? NSObject)
        #expect(page.window.firstResponder === secondEditor)
        #expect(after === before)
        #expect(fixture.vm.questions.last?.draft == "B draft")
    }

    @Test func givenFocusedComposingQuestion_whenSameRowIDGetsNewCheckpoint_thenEditorMountAndDraftDoNotTransfer() async throws {
        // given
        let fixture = QuestionCardHostedFixture()
        let page = mount(fixture)
        defer { fixture.vm.didDisappear(); page.close() }
        await ready(page, fixture)
        let oldCard = try #require(fixture.vm.questions.first)
        let oldEditor = try #require(page.descendants.compactMap { $0 as? NSTextView }.first { $0.isEditable })
        #expect(page.window.makeFirstResponder(oldEditor))
        oldEditor.insertText("Old draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        await page.settle { fixture.vm.questionDraft(for: oldCard) == "Old draft" }
        oldEditor.setMarkedText("Old composition", selectedRange: NSRange(location: 3, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(oldEditor.hasMarkedText())
        var replacement = oldCard.item
        replacement.attentionCheckpointID = "replacement checkpoint"
        // when — the list row ID stays identical while the exact request/mount changes.
        fixture.useCase.subject.send(.init(phase: .ready, items: [replacement]))
        fixture.vm.setQuestionDraft("Stale callback", for: oldCard)
        fixture.vm.submitQuestion(oldCard, offered: nil)
        await page.settle {
            fixture.vm.presentation.questions.contains { $0.item == replacement && $0.id != oldCard.id }
                && page.descendants.compactMap { $0 as? NSTextView }.contains { $0.isEditable && $0 !== oldEditor }
        }
        // then
        let freshCard = try #require(fixture.vm.questions.first { $0.item == replacement })
        let freshEditor = try #require(page.descendants.compactMap { $0 as? NSTextView }.first { $0.isEditable && $0 !== oldEditor })
        #expect(freshCard.id != oldCard.id)
        #expect(freshCard.draft.isEmpty && freshEditor.string.isEmpty)
        #expect(!freshEditor.hasMarkedText())
        #expect(page.window.firstResponder !== freshEditor)
        #expect(page.window.firstResponder !== oldEditor)
        #expect(fixture.useCase.answerCalls == 0)
    }

    /// SwiftUI AX nodes expose the getter without declaring NSAccessibilityProtocol conformance.
    private static func isEnabled(_ object: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return getter(object, selector)
    }

    private func mount(_ fixture: QuestionCardHostedFixture, dark: Bool = false, minimum: Bool = false) -> RedesignHost {
        let page = RedesignHost(NeedsYouView(fixture.vm, itemID: nil)
            .preferredColorScheme(dark ? .dark : .light)
.environment(\.hfReduceMotionOverride, true),
            size: minimum ? CGSize(width: 1000, height: 620) : CGSize(width: 1280, height: 800), appearance: dark ? .dark : .light)
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return page
    }

    private func ready(_ page: RedesignHost, _ fixture: QuestionCardHostedFixture, question: String = QuestionCardHostedFixture.question) async {
        await page.settle { NSApp.isActive && page.window.isKeyWindow && fixture.vm.presentation.questions.count == 1 && page.element(question) != nil }
    }

    private func capture(_ page: RedesignHost, name: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M07_QUESTION_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await DisplayFrames.waitForPresentedFrame()
        try await M04NativeWindowEvidence.record(window: page.window, name: "m07-question-after-\(name)", directory: directory)
    }
}
