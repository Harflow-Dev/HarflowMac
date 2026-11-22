import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct StatisticsTaskSummaryExclusionTests: StatisticsFixtures {

    // MARK: Invalid records

    @Test func givenMissingOrEmptyTaskID_whenSummarised_thenNotCountedAndReported() {
        // given
        let facts = [task("a", taskID: .some(nil)), task("b", taskID: .some("")), task("ok")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
        #expect(result.coverage.contains("2 execution records couldn't be read and aren't counted."))
    }

    @Test func givenTaskIDRepeatedAmongOtherwiseValidRecords_whenSummarised_thenBothAreInvalid() {
        // given
        let facts = [task("x", taskID: .some("dup")), task("y", taskID: .some("dup")), task("ok")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
        #expect(result.coverage.contains("2 execution records couldn't be read and aren't counted."))
    }

    @Test func givenUnknownOrWorkflowOnlyKind_whenSummarised_thenNotCounted() {
        // given
        let facts = [task("a", kind: "future"), task("b", kind: "control"), task("c", kind: "native")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.coverage.contains("3 execution records couldn't be read and aren't counted."))
    }

    @Test func givenKindThatDisagreesWithLinks_whenSummarised_thenNotCounted() {
        // given
        let facts = [
            task("a", kind: "initial", parent: "x"), task("b", kind: "resume"),
            task("c", kind: "continuation", parent: "x"), task("ok")
        ]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
        #expect(result.coverage.contains("3 execution records couldn't be read and aren't counted."))
    }

    @Test func givenContinuationCarryingParentLink_whenSummarised_thenItIsValid() {
        // given
        let facts = [task("a"), task("b", kind: "continuation", parent: "a", continuation: "a")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
        #expect(!result.coverage.contains { $0.contains("couldn't be read") })
    }

    @Test func givenLinkCycle_whenSummarised_thenWholeCycleIsInvalidAndTailsAreInvalidToo() {
        // given
        let facts = [task("a", parent: "b"), task("b", parent: "a"), task("c", parent: "a")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.coverage.contains("3 execution records couldn't be read and aren't counted."))
    }

    @Test func givenInvalidPredecessorWithValidSuccessor_whenSummarised_thenSuccessorIsFirstRunUnidentified() {
        // given
        let facts = [task("a", kind: "future"), task("b", parent: "a")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.coverage.contains("1 execution record couldn't be read and isn't counted."))
        #expect(result.coverage.contains(
            "1 later execution isn't counted because its first run couldn't be identified in the available history."
        ))
    }

    @Test func givenChainOfExactlyOneThousandHops_whenSummarised_thenItCounts() {
        // given
        let facts = chain(hops: 1000)

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
    }

    @Test func givenChainOfOneThousandAndOneHops_whenSummarised_thenWholeChainIncludingRootIsInvalid() {
        // given
        let facts = chain(hops: 1001)

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.coverage.contains("1002 execution records couldn't be read and aren't counted."))
    }

    // MARK: Scale

    @Test func givenThousandHopChain_whenSummarised_thenResolutionIsLinear() {
        // given
        let facts = chain(hops: 1000)

        // when
        let built = StatisticsProjection.standaloneChains(facts)

        // then
        #expect(built.chains.count == 1)
        #expect(built.resolutionSteps <= facts.count)
    }

    @Test func givenTwentyThousandFactsInDeepChains_whenResolved_thenEachTaskIsVisitedOnce() {
        // given: 20 chains of 1,000 facts; repeated walks would need about 10 million steps
        var facts: [StatisticsFact] = []
        for index in 0 ..< 20 {
            facts.append(task("c\(index)-0"))
            for hop in 1 ..< 1000 { facts.append(task("c\(index)-\(hop)", parent: "c\(index)-\(hop - 1)")) }
        }

        // when
        let built = StatisticsProjection.standaloneChains(facts)

        // then
        #expect(facts.count == 20000)
        #expect(built.chains.count == 20)
        #expect(built.excluded.isEmpty)
        #expect(built.resolutionSteps <= facts.count)
    }
}
