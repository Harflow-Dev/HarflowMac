import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - TaskPaneChipFocusTests responders

extension TaskPaneChipFocusTests {
    private final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func givenAHiddenParentAboveAnUnhiddenChipAndResponder_whenResolved_thenThereIsNoTarget() {
        // given the chip and its responder are unhidden themselves, but an ancestor outside the entry is hidden
        let parent = NSView()
        parent.isHidden = true
        let chip = NSView()
        chip.addSubview(Focusable())
        parent.addSubview(chip)

        // then
        #expect(!chip.isHidden && TaskPaneChipFocus.uniqueResponder(in: chip) == nil)
    }

    @Test func givenAHiddenContainerWithAnUnhiddenFocusableChild_whenResolved_thenThereIsNoTarget() {
        // given the child's own isHidden is false, but its container is hidden: it is not visible
        let chip = NSView()
        let container = NSView()
        container.isHidden = true
        container.addSubview(Focusable())
        chip.addSubview(container)

        // then
        #expect(TaskPaneChipFocus.uniqueResponder(in: chip) == nil)
    }

    @Test func givenAHiddenChipRoot_whenResolved_thenThereIsNoTarget() {
        // given
        let chip = Focusable()
        chip.isHidden = true

        // then
        #expect(TaskPaneChipFocus.uniqueResponder(in: chip) == nil)
    }

    @Test func givenAHiddenSiblingBesideTheOnlyVisibleResponder_whenResolved_thenTheVisibleOneIsTheTarget() {
        // given
        let chip = NSView()
        let hidden = NSView()
        hidden.isHidden = true
        hidden.addSubview(Focusable())
        let visible = Focusable()
        chip.addSubview(hidden)
        chip.addSubview(visible)

        // then
        #expect(TaskPaneChipFocus.uniqueResponder(in: chip) === visible)
    }

    // MARK: - Target (single responder)

    @Test func givenAChipView_whenOneDescendantAcceptsFocus_thenThatOneIsTheTarget() {
        // given
        let chip = NSView()
        let inner = NSView()
        let target = Focusable()
        chip.addSubview(inner)
        inner.addSubview(target)
        inner.addSubview(NSView())

        // then
        #expect(TaskPaneChipFocus.uniqueResponder(in: chip) === target)
    }

    @Test func givenTheChipViewItselfAcceptsFocus_whenNoDescendantDoes_thenItIsTheTarget() {
        // given
        let chip = Focusable()
        chip.addSubview(NSView())

        // then
        #expect(TaskPaneChipFocus.uniqueResponder(in: chip) === chip)
    }

    @Test func givenNoOrSeveralOrOnlyHiddenResponders_whenResolved_thenThereIsNoTarget() {
        // given
        let none = NSView()
        none.addSubview(NSView())
        let several = NSView()
        several.addSubview(Focusable())
        several.addSubview(Focusable())
        let hidden = NSView()
        let hiddenTarget = Focusable()
        hiddenTarget.isHidden = true
        hidden.addSubview(hiddenTarget)

        // then
        #expect(TaskPaneChipFocus.uniqueResponder(in: none) == nil)
        #expect(TaskPaneChipFocus.uniqueResponder(in: several) == nil, "an ambiguous item is not guessed at")
        #expect(TaskPaneChipFocus.uniqueResponder(in: hidden) == nil)
    }
}
