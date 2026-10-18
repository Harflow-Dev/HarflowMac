import MonitorCore
@testable import PbUI
import Testing

// MARK: - StatusBadgeTests

@Suite struct StatusBadgeTests {

    @Test func givenEachPrescribedState_whenMapped_thenIndicatorLabelAndTintMatchTheDesign() {
        // given / when / then — the six prescribed states of SPEC §5.1.
        let running = StatusBadge.presentation(for: .running)
        #expect(running == StatusBadgePresentation(indicator: .spinner, label: "Running", tint: .running))

        let done = StatusBadge.presentation(for: .completed)
        #expect(done == StatusBadgePresentation(indicator: .symbol("checkmark"), label: "Done", tint: .done))

        let attention = StatusBadge.presentation(for: .other("needs_input"))
        #expect(attention == StatusBadgePresentation(indicator: .symbol("exclamationmark.triangle.fill"), label: "Needs attention", tint: .warning))

        let failed = StatusBadge.presentation(for: .failed)
        #expect(failed == StatusBadgePresentation(indicator: .symbol("xmark"), label: "Failed", tint: .danger))

        let pending = StatusBadge.presentation(for: .other("pending"))
        #expect(pending == StatusBadgePresentation(indicator: .symbol("circle"), label: "Pending", tint: .pending))

        let cancelled = StatusBadge.presentation(for: .cancelled)
        #expect(cancelled == StatusBadgePresentation(indicator: .symbol("stop.fill"), label: "Cancelled", tint: .pending))
    }

    @Test func givenTimedOut_whenMapped_thenItKeepsItsOwnLabelAndSharesTheFailedStyling() {
        // given / when
        let timedOut = StatusBadge.presentation(for: .timedOut)

        // then — timed out stays distinguishable from failed by its word, never by colour alone.
        #expect(timedOut.label == "Timed out")
        #expect(timedOut.tint == StatusBadge.presentation(for: .failed).tint)
        #expect(timedOut.indicator == .symbol("xmark"))
    }

    @Test func givenPendingAndQueuedRawStatuses_whenMapped_thenBothReadAsPending() {
        // given / when
        let pending = StatusBadge.presentation(for: .other("pending"))
        let queued = StatusBadge.presentation(for: .other("Queued"))

        // then — the only raw statuses mapped to a drawn state; case and underscores are noise.
        #expect(pending == queued)
        #expect(queued.label == "Pending")
    }

    @Test func givenNeedsInputVariants_whenMapped_thenAllReadAsNeedsAttention() {
        // given / when / then — normalized case and underscores.
        for raw in ["needs_input", "Needs Input", "NEEDS_ATTENTION", "needs attention"] {
            let presentation = StatusBadge.presentation(for: .other(raw))
            #expect(presentation.label == "Needs attention", "\(raw)")
            #expect(presentation.tint == .warning, "\(raw)")
            #expect(presentation.indicator == .symbol("exclamationmark.triangle.fill"), "\(raw)")
        }
    }

    @Test func givenSettling_whenMapped_thenASpinnerKeepsTheHonestSettlingLabel() {
        // given / when
        let settling = StatusBadge.presentation(for: .other("settling"))

        // then — a transient state, drawn on the running tint but labelled Settling, never Running.
        #expect(settling.indicator == .spinner)
        #expect(settling.label == "Settling")
        #expect(settling.tint == .running)
    }

    @Test func givenAnyOtherRawStatus_whenMapped_thenItRetainsItsRawLabelOnTheUnknownTreatment() {
        // given / when / then — an unmapped status is never guessed into a state; its raw label,
        // the dashed-circle icon and the secondaryText tint say exactly what polybridge said.
        for raw in ["unknown", "mystery-state", "waiting_for_owner"] {
            let presentation = StatusBadge.presentation(for: .other(raw))
            #expect(presentation.label == raw, "\(raw)")
            #expect(presentation.indicator == .symbol("circle.dashed"), "\(raw)")
            #expect(presentation.tint == .unknown, "\(raw)")
        }
    }

    @Test func givenTheBadge_whenSpoken_thenItAnnouncesStateElapsedAndTakenOverAsOneElement() {
        // given / when / then — the complete spoken strings: the mapped state label first, then
        // the supplied elapsed time, then the taken-over annotation, each only when present.
        #expect(StatusBadge.accessibilityLabel(stateLabel: "Running", elapsedText: "1:30", isTakenOver: false) == "Running, 1:30")
        #expect(StatusBadge.accessibilityLabel(stateLabel: "Done", elapsedText: "6:52", isTakenOver: true) == "Done, 6:52, taken over")
        #expect(StatusBadge.accessibilityLabel(stateLabel: "Failed", elapsedText: nil, isTakenOver: false) == "Failed")
        #expect(StatusBadge.accessibilityLabel(stateLabel: "Failed", elapsedText: nil, isTakenOver: true) == "Failed, taken over")
    }

    @Test func givenSettlingAndRunningBadges_whenSpoken_thenSettlingIsNotAnnouncedAsRunning() {
        // given — the decorative spinner carries its own "Running" label; the badge ignores its
        // children and speaks the mapped state label, so settling is never read as running and
        // running is never announced twice.
        let settling = StatusBadge.presentation(for: .other("settling"))
        let running = StatusBadge.presentation(for: .running)

        // when
        let settlingSpoken = StatusBadge.accessibilityLabel(stateLabel: settling.label, elapsedText: nil, isTakenOver: false)
        let runningSpoken = StatusBadge.accessibilityLabel(stateLabel: running.label, elapsedText: nil, isTakenOver: false)

        // then
        #expect(settlingSpoken == "Settling")
        #expect(runningSpoken == "Running")
        #expect(settlingSpoken != runningSpoken)
    }

    @Test func givenAMappedStatus_whenSpoken_thenTheSpokenLabelIsTheMappedLabelNotTheRawOne() {
        // given / when / then — VoiceOver reads what the badge draws: raw "queued" is spoken as
        // "Pending", raw "needs_attention" as "Needs attention".
        #expect(StatusBadge.accessibilityLabel(
            stateLabel: StatusBadge.presentation(for: .other("queued")).label,
            elapsedText: nil,
            isTakenOver: false
        ) == "Pending")
        #expect(StatusBadge.accessibilityLabel(
            stateLabel: StatusBadge.presentation(for: .other("needs_attention")).label,
            elapsedText: nil,
            isTakenOver: false
        ) == "Needs attention")
    }

    @Test func givenCallerSuppliedOverride_whenResolved_thenItWinsOverTheSharedMapping() {
        // given — a workflow caller's honest presentation for a raw status the shared mapping
        // would draw as unknown.
        let override = StatusBadgePresentation(indicator: .spinner, label: "Starting", tint: .running)

        // when
        let resolved = StatusBadge.effectivePresentation(for: .other("starting"), override: override)

        // then — the override drives the badge; the raw status itself is never reinterpreted.
        #expect(resolved == override)
        #expect(resolved != StatusBadge.presentation(for: .other("starting")))
    }

    @Test func givenNoOverride_whenResolved_thenEveryExistingMappingIsUnchanged() {
        // given / when / then — the default nil keeps each shared task/menu mapping intact.
        let statuses: [TaskStatus] = [
            .running, .completed, .failed, .timedOut, .cancelled,
            .other("pending"), .other("Queued"), .other("settling"),
            .other("needs_input"), .other("mystery-state")
        ]
        for status in statuses {
            #expect(StatusBadge.effectivePresentation(for: status, override: nil) == StatusBadge.presentation(for: status), "\(status)")
        }
    }
}
