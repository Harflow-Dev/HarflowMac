@testable import MainWindowFeature
import Testing

// MARK: - ActivityFeedTailPresentationTests

struct ActivityFeedTailPresentationTests {
    @Test func givenNoOverride_whenStandardPresentationIsBuilt_thenCancelIsEnabled() {
        // given / when
        let standard = ActivityFeedTailPresentation.Standard()
        // then
        #expect(standard.cancel == .enabled)
    }

    @Test(arguments: [
        (ActivityFeedTailPresentation.CancelAvailability.enabled, ActivityFeedTailPresentation.CancelAvailability.disabled),
        (.enabled, .hidden),
        (.disabled, .hidden)
    ])
    func givenTwoStandardValuesDifferingOnlyInCancel_whenCompared_thenTheyAreUnequal(
        first: ActivityFeedTailPresentation.CancelAvailability, second: ActivityFeedTailPresentation.CancelAvailability
    ) {
        // given
        let left = ActivityFeedTailPresentation.Standard(cancel: first)
        let right = ActivityFeedTailPresentation.Standard(cancel: second)
        // when / then
        #expect(left != right)
        #expect(ActivityFeedTailPresentation.standard(left) != ActivityFeedTailPresentation.standard(right))
    }

    @Test func givenSameCancelState_whenCompared_thenStandardValuesAreEqual() {
        // given
        let left = ActivityFeedTailPresentation.Standard(cancel: .disabled)
        let right = ActivityFeedTailPresentation.Standard(cancel: .disabled)
        // when / then
        #expect(left == right)
    }

    @Test func givenWorkMessagesOnly_whenCheckingTailVisibility_thenTheTailIsVisible() {
        // given
        let bubble = WorkMessageBubble(id: "m", seq: 1, kind: .queued(canCancel: true, note: nil), text: "hold")
        let withBubble = ActivityFeedTailPresentation.standard(.init(workMessages: [bubble]))
        let empty = ActivityFeedTailPresentation.standard(.init())
        // when / then
        #expect(withBubble.isVisible(with: ActivityFeedTail()))
        #expect(!empty.isVisible(with: ActivityFeedTail()))
    }
}
