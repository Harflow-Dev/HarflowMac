import Foundation
import HfRepository
@testable import MainWindowFeature
import Testing

// MARK: - NeedsYouPresentationTests

struct NeedsYouPresentationTests {
    @Test func givenUnreadableAndDeferredSources_whenMapped_thenOnlyRealFailuresShowTheErrorNotice() {
        // given / when
        let failed = NeedsYouPresentationMapper.presentation(NeedsYouSnapshot(phase: .ready, unreadableSourceCount: 2), leaving: [])
        let deferred = NeedsYouPresentationMapper.presentation(NeedsYouSnapshot(phase: .ready, deferredSourceCount: 3), leaving: [])
        // then
        #expect(failed.partialNotice == "Could not read 2 runs. Showing the requests Harflow could read." && failed.checkingNote == nil)
        #expect(deferred.partialNotice == nil && deferred.checkingNote == "Checking more runs…")
    }

    @Test func givenLowerBound_whenSummarized_thenAtLeastWording() {
        let item = NeedsYouItem(id: "input:a:b", kind: .question, runTitle: "R", text: "t",
                                ownership: .init(owner: "monitor", callerEnded: false, engineNote: "", handover: nil), startedBy: "Mac app")
        let lowerBound = NeedsYouSnapshot(phase: .ready, items: [item], unreadableSourceCount: 1)
        #expect(NeedsYouPresentationMapper.summary(lowerBound) == "At least 1 request you can answer")
        #expect(NeedsYouPresentationMapper.summary(NeedsYouSnapshot(phase: .ready)) == "Nothing needs you")
        #expect(NeedsYouPresentationMapper.summary(NeedsYouSnapshot(phase: .loading)).hasPrefix("Checking"))
    }

    @Test func givenLongText_whenMapped_thenRowAndDetailThresholdsApply() {
        let short = NeedsYouRow(id: "a", kind: .question, kindLabel: "Question", title: "t", pathTitles: [], startedBy: "", callerEnded: false,
                                text: String(repeating: "x", count: 180), waitingSince: nil)
        let long = NeedsYouRow(id: "a", kind: .question, kindLabel: "Question", title: "t", pathTitles: [], startedBy: "", callerEnded: false,
                               text: String(repeating: "x", count: 181), waitingSince: nil)
        #expect(!short.isLong && long.isLong)
    }

    @Test func givenHandoverRecord_whenMapped_thenProvenanceAndOwnershipCopyDescribeIt() {
        // given
        let handover = NeedsYouItem.Handover(timestamp: Date(timeIntervalSince1970: 0), reason: "pid_absent", previousOwner: "caller")
        let item = NeedsYouItem(id: "input:a:b", kind: .question, rootRunID: "a", runTitle: "R", pathTitles: ["R", "N"], text: "t",
                                ownership: .init(owner: "monitor", callerEnded: true, engineNote: "note", handover: handover), startedBy: "Original caller")
        // when
        let detail = NeedsYouPresentationMapper.detail(item)
        // then
        #expect(detail.provenance.map(\.label) == ["Run", "Path", "Started by", "Caller", "Owner", "Engine note", "Handover"])
        #expect(detail.ownershipNote == "Harflow owns this run, so you can answer here. The original caller can no longer answer it.")
    }

    @Test func givenCallerEndedWorkflowItem_whenMapped_thenOwnershipWarnsAboutHandoverAndRecheck() {
        let item = NeedsYouItem(id: "input:a:b", kind: .question, rootRunID: "a", runTitle: "R", text: "t",
                                ownership: .init(owner: "caller", callerEnded: true, engineNote: "", handover: nil), startedBy: "Original caller")
        let note = NeedsYouPresentationMapper.detail(item).ownershipNote
        #expect(note.contains("Answering hands this run to Harflow") && note.contains("the engine may refuse"))
    }

    @Test func givenAge_whenFormatted_thenMinuteGranularity() {
        let now = Date(timeIntervalSince1970: 10000)
        #expect(NeedsYouAgeText.age(since: now.addingTimeInterval(-20), now: now) == "just now")
        #expect(NeedsYouAgeText.age(since: now.addingTimeInterval(-42 * 60), now: now) == "42 min ago")
        #expect(NeedsYouAgeText.age(since: now.addingTimeInterval(-180 * 60), now: now) == "3 h ago")
    }

    @Test func givenBadge_whenBuilt_thenStatesAndLabelsFollowTheDesign() {
        let item = NeedsYouItem(id: "input:a:b", kind: .question, runTitle: "R", text: "t",
                                ownership: .init(owner: "monitor", callerEnded: false, engineNote: "", handover: nil), startedBy: "Mac app")
        #expect(NeedsYouBadge(NeedsYouSnapshot(phase: .loading)) == .loading)
        #expect(NeedsYouBadge(NeedsYouSnapshot(phase: .ready)) == .none)
        #expect(NeedsYouBadge(NeedsYouSnapshot(phase: .ready, items: [item, item, item])) == .count(3, atLeast: false))
        #expect(NeedsYouBadge(NeedsYouSnapshot(phase: .ready, items: [item], deferredSourceCount: 1)) == .count(1, atLeast: true))
        #expect(NeedsYouBadge.count(3, atLeast: false).accessibilityLabel == "Needs you, 3 pending")
        #expect(NeedsYouBadge.count(3, atLeast: true).accessibilityLabel == "Needs you, at least 3 pending")
        #expect(NeedsYouBadge.none.accessibilityLabel == "Needs you, nothing pending")
        #expect(NeedsYouBadge.loading.accessibilityLabel == "Needs you, loading")
        #expect(NeedsYouBadge.none.capsuleText == nil && NeedsYouBadge.count(3, atLeast: true).capsuleText == "3+")
    }
}
