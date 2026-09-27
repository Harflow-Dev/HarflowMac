@testable import PbUI
import Testing

/// `DeferredContent` itself can't be driven without a SwiftUI rendering harness, so its swap logic
/// lives in `DeferredContentState` (Monitor piece 12) precisely so it is directly testable here.
@MainActor
@Suite struct DeferredContentStateTests {

    @Test func givenAFreshState_whenCreated_thenItStartsOnThePlaceholder() {
        // given / when
        let state = DeferredContentState(waitForPresentedFrame: {})

        // then
        #expect(state.isShowingContent == false)
    }

    @Test func givenAFreshState_whenRevealAfterFirstFrameCompletes_thenItSwitchesToContent() async {
        // given
        let state = DeferredContentState(waitForPresentedFrame: {})

        // when
        await state.revealAfterFirstFrame()

        // then
        #expect(state.isShowingContent == true)
    }

    @Test(.timeLimit(.minutes(1))) func givenAFrameNotYetPresented_whenRevealing_thenItStaysOnThePlaceholderUntilTheFrameIs() async {
        // given — the swap must wait for the frame boundary, not run ahead of it.
        let gate = FrameGate()
        let state = DeferredContentState(waitForPresentedFrame: { await gate.wait() })

        // when
        let reveal = Task { await state.revealAfterFirstFrame() }
        await gate.waitUntilEntered()

        // then
        #expect(state.isShowingContent == false)
        gate.open()
        await reveal.value
        #expect(state.isShowingContent == true)
    }

    @Test func givenContentAlreadyShowing_whenRevealAfterFirstFrameIsCalledAgain_thenItStaysShowingContent() async {
        // given — the guard makes a repeated call (e.g. `.task` re-running) a cheap no-op rather than
        // re-running the frame-commit wait.
        let state = DeferredContentState(waitForPresentedFrame: {})
        await state.revealAfterFirstFrame()

        // when
        await state.revealAfterFirstFrame()

        // then
        #expect(state.isShowingContent == true)
    }
}

/// A frame boundary a test opens by hand.
@MainActor
private final class FrameGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var hasEntered = false

    func wait() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    /// Returns once the reveal is actually parked at the boundary, so an assertion made after it
    /// really observes the wait rather than a reveal that has not started yet.
    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
