import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - M05StateTableTests

/// A consistency check of the state table. It reads no design files and proves nothing about pixels.
@Suite struct M05StateTableTests {

    /// The design's task-state route ids at 4ff7d83, typed out independently of the table: the `task` routes of
    /// `screens-m05-proposal.js` ROUTES (status, actions, top bar, layout, changes, artifacts, events), the eight transcript
    /// states of `screens-transcript.js`, `loading` and `loading-pane` of `screens-loading-work.js` and `approval` of
    /// `registry.js`. Provisional message, approval-state and pending-launch families are listed as excluded families.
    static let designRouteIDs: Set<String> = [
        "running-stop", "stop-requested", "cancelled", "cancelled-partial", "timed-out", "settling", "unknown-failed",
        "unknown-done", "owner-lost", "unverified", "launch-unknown", "status-unavailable", "pending", "taken-over",
        "continue-starting", "continue-started", "continue-refused", "failed-continue",
        "overflow-running", "overflow-settled", "overflow-subtask", "stop-dialog", "stop-dialog-earlier-turns", "takeover-dialog",
        "topbar-facts", "topbar-resource", "topbar-minimum",
        "pane-overlay", "pane-split", "pane-running-closed", "pane-running-open", "pane-failed-closed",
        "changes-single", "changes-multi", "changes-multi-limited", "changes-same-path", "changes-row-states", "changes-incomplete",
        "changes-not-captured", "changes-unmerged", "changes-running", "changes-zero", "changes-no-repository", "changes-text",
        "changes-loading", "changes-error", "changes-turns",
        "artifacts-populated", "artifacts-page-error", "artifacts-empty", "artifacts-loading", "artifacts-error",
        "events-populated", "events-page", "events-page-error", "events-not-started", "events-loading", "events-empty", "events-error",
        "transcript-observed", "transcript-loading", "transcript-partial", "transcript-unavailable", "transcript-integrity-failed",
        "transcript-reconnecting", "transcript-capacity", "transcript-sources",
        "loading", "loading-pane", "approval"
    ]

    @Test func givenTheTable_whenCountingStates_thenEachSuiteHasItsPinnedCount() {
        // given / when
        let counts = Dictionary(uniqueKeysWithValues: M05StateTable.Suite.allCases.map { ($0, M05StateTable.ids($0).count) })

        // then
        #expect(counts[.status] == 16)
        #expect(counts[.actionsTopBar] == 9)
        #expect(counts[.pane] == 11)
        #expect(counts[.changes] == 15)
        #expect(counts[.transcript] == 10)
        #expect(M05StateTable.designCommit == "4ff7d83")
    }

    @Test func givenTheTable_whenListingRenderedStates_thenIdsAreUniqueAndEqualApprovedMinusExclusions() {
        // given
        let rendered = M05StateTable.all.filter { $0.notRenderable == nil }.map(\.id)
        let excluded = Set(M05StateTable.exclusions.map(\.id))

        // when
        let union = Set(rendered)

        // then
        #expect(rendered.count == union.count, "a state id is mounted twice")
        #expect(union == Self.designRouteIDs.subtracting(excluded), "rendered ids differ from the design's approved list")
        #expect(excluded.isSubset(of: Self.designRouteIDs))
        #expect(Self.designRouteIDs.count == 70)
        #expect(union.isDisjoint(with: excluded))
        #expect(rendered.count == 61)
    }

    @Test func givenEveryExclusionAndDeviation_whenRead_thenItCarriesAReason() {
        // given / when / then
        for exclusion in M05StateTable.exclusions { #expect(!exclusion.reason.isEmpty, "\(exclusion.id)") }
        for family in M05StateTable.excludedFamilies { #expect(!family.reason.isEmpty, "\(family.prefix)") }
        for entry in M05StateTable.all {
            #expect(entry.deviation?.isEmpty != true, "\(entry.id)")
            #expect(entry.notRenderable?.isEmpty != true, "\(entry.id)")
            #expect(entry.designRoute == "task/" + entry.id)
            #expect(entry.designFile.hasPrefix("v2/scripts/"))
            #expect(!entry.recipe.isEmpty)
        }
        for entry in M05StateTable.all where entry.notRenderable != nil {
            #expect(M05StateTable.exclusions.contains { $0.id == entry.id }, "\(entry.id) is not renderable but not an exclusion")
        }
    }
}
