import Foundation
@testable import MonitorCore
import Testing

@Suite(.serialized)
struct RefreshTriggerTests {
    @Test
    func givenPhaseAndRecordFileNames_whenCheckedForRelevance_thenOnlyPhaseAndRecordFilesTriggerARefresh() {
        // given / when / then
        #expect(RefreshTrigger.isRelevant("abc.meta.json"))
        #expect(RefreshTrigger.isRelevant("abc.takeover.1.ready"))
        #expect(RefreshTrigger.isRelevant("abc.takeover.2.attach"))
        #expect(RefreshTrigger.isRelevant("abc.cancel.1.sig"))
        #expect(!RefreshTrigger.isRelevant("abc.events.jsonl"))
        #expect(!RefreshTrigger.isRelevant("abc.jsonl"))
    }
}

@Suite(.serialized)
struct CascadeSummaryTests {
    @Test
    func givenACascadeWithSurvivorsAndUnsignalled_whenDescribed_thenItSaysWhatDidNotStop() {
        // given
        let result: [String: JSONValue] = [
            "task_id": .string("t"), "status": .string("cancelled"),
            "cascade": .object([
                "cancelled_descendants": .array([.string("a"), .string("b")]),
                "sigkill_survivors": .array([.string("c")]),
                "not_signalled": .array([.object(["task_id": .string("d"), "reason": .string("x")])]),
                "owner_still_settling": .array([])
            ])
        ]
        // when
        let text = CascadeSummary.describe(result)
        // then
        #expect(text.contains("status cancelled"))
        #expect(text.contains("2 sub-tasks cancelled"))
        #expect(text.contains("1 survived SIGKILL"))
        #expect(text.contains("1 not signalled"))
        #expect(!text.contains("settling"))
    }

    @Test
    func givenAnIncompleteCascade_whenDescribed_thenItIsSaid() {
        // given
        let result: [String: JSONValue] = ["status": .string("cancelled"), "cascade": .object([
            "cascade_incomplete": .bool(true), "unconverged": .array([.string("x"), .string("y")])
        ])]
        // when / then
        #expect(CascadeSummary.describe(result).contains("cascade incomplete: 2 descendants never reached"))
    }

    @Test
    func givenAPlainCancelWithNoCascade_whenDescribed_thenOnlyTheStatusIsShown() {
        // given / when / then
        #expect(CascadeSummary.describe(["status": .string("cancelled")]) == "Cancel sent · status cancelled")
    }
}
