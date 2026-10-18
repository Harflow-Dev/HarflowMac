@testable import MainWindowFeature
import Testing

// MARK: - WorkflowRunStatusTests

struct WorkflowRunStatusTests {
    @Test func givenMatchingRecoveryReason_whenFallbackIsPresented_thenOnlyVisibleBannerDuplicateIsSuppressed() {
        // given
        let reason = "  Attempt limit reached.\n"
        // when / then
        #expect(WorkflowDecisionFallback.text(status: "needs_attention", reason: reason, hasWorkerStep: true,
            recoveryQuestion: "Attempt limit reached.") == nil)
        #expect(WorkflowDecisionFallback.text(status: "needs_attention", reason: reason, hasWorkerStep: true) == reason)
        #expect(WorkflowDecisionFallback.text(status: "needs_attention", reason: reason, hasWorkerStep: true,
            recoveryQuestion: "Which approach should continue?") == reason)
        #expect(WorkflowRecoveryPresentation.showsRecovery(status: "needs_attention", allowsMonitorControl: true, isDelegation: false))
        #expect(!WorkflowRecoveryPresentation.showsRecovery(status: "needs_attention", allowsMonitorControl: false, isDelegation: false))
        #expect(WorkflowRecoveryPresentation.showsRecovery(status: "failed", allowsMonitorControl: true, isDelegation: true))
        #expect(!WorkflowRecoveryPresentation.showsRecovery(status: "failed", allowsMonitorControl: true, isDelegation: false))
    }

    @Test func givenFreshStartingOrRunningRun_whenFallbackProjected_thenWaitingForFirstStepIsHonest() {
        // given / when / then — the waiting line appears only while nothing contradicts it.
        for status in ["starting", "running"] {
            #expect(WorkflowDecisionFallback.text(status: status, reason: "", hasWorkerStep: false)
                    == WorkflowDecisionFallback.waitingForFirstStep, "\(status)")
        }
    }

    @Test func givenAttentionOrErrorReason_whenFallbackProjected_thenTheReportedReasonWins() {
        // given / when / then
        #expect(WorkflowDecisionFallback.text(status: "needs_attention",
                                              reason: "Implementation reached its attempt limit.",
                                              hasWorkerStep: false)
                == "Implementation reached its attempt limit.")
        #expect(WorkflowDecisionFallback.text(status: "failed", reason: "Scheduler refused the decision.", hasWorkerStep: true)
                == "Scheduler refused the decision.")
    }

    @Test func givenAttentionOrErrorStateWithoutReason_whenFallbackProjected_thenNoWaitingContradiction() {
        // given / when / then — an attention, input, paused, failed or terminal state never
        // shows "Waiting for the first step" beside the state that contradicts it.
        for status in ["needs_attention", "needs_input", "paused", "failed", "completed", "cancelled"] {
            #expect(WorkflowDecisionFallback.text(status: status, reason: "", hasWorkerStep: false) == nil, "\(status)")
        }
    }

    @Test func givenStartedWorkerStep_whenFallbackProjected_thenWaitingIsWithdrawn() {
        // given / when / then — a worker step that has started withdraws the waiting line even
        // while the raw status is still running.
        #expect(WorkflowDecisionFallback.text(status: "running", reason: "", hasWorkerStep: true) == nil)
    }
}
