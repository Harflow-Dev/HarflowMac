import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - StartScreenVMLifecycleClockTests

@MainActor
@Suite struct StartScreenVMLifecycleClockTests {
    @Test func givenCompleteHistory_whenOnlyTheClockChanges_thenPresentationRecomputesWithoutAnotherRead() async {
        // given
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let initial = utc.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8))!
        let fixture = StartScreenVMLifecycleTests().makeSUT(start: initial)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        let readCount = await fixture.source.counts()

        // when
        fixture.clock.advance(10 * 60 * 60)
        await fixture.sut.tick()
        let forwardGreeting = fixture.sut.presentation.greeting
        let forwardReads = await fixture.source.counts()
        fixture.clock.advance(-12 * 60 * 60)
        await fixture.sut.tick()
        let backwardReads = await fixture.source.counts()

        // then
        #expect(forwardGreeting == "Good evening")
        #expect(fixture.sut.presentation.greeting == "Early start")
        #expect(fixture.sut.presentation.status == "Nothing running.")
        #expect(forwardReads.0 == readCount.0 && forwardReads.1 == readCount.1 && forwardReads.2 == readCount.2)
        #expect(backwardReads.0 == readCount.0 && backwardReads.1 == readCount.1 && backwardReads.2 == readCount.2)
        fixture.sut.didDisappear()
    }

    @Test func givenProductionReplayAndProgressSnapshots_whenFirstScanCompletes_thenItDoesNotWaitForThrottle() async {
        // given
        let source = StartScreenProbeSource()
        let useCase = MockStartScreenUseCase()
        let routing = MockStartScreenRouting()
        let clock = StartScreenTestClock(Date(timeIntervalSince1970: 1_790_000_000))
        let replay = CurrentValueSubject<[TaskInfo], Never>([
            TaskInfo(.object(["task_id": .string("task"), "status": .string("running"), "workflow_run_id": .null,
                              "duration_seconds": .number(1)]))!
        ])
        given(useCase).source.willReturn(source)
        given(useCase).changes().willReturn(StartScreenViewRepository.semanticChanges(replay.eraseToAnyPublisher()))
        given(useCase).errors().willReturn(StartScreenViewRepository.semanticErrors(Just(nil).eraseToAnyPublisher()))
        given(useCase).historyState().willReturn(StartScreenViewRepository.semanticHistoryState(Just(HistoryLoadingState()).eraseToAnyPublisher()))
        let sut = StartScreenVM(useCase: useCase, routing: routing, now: { clock.read() }, uptime: { clock.readUptime() },
                                refreshInterval: 30, tickInterval: .seconds(3_600))
        sut.didAppear()

        // The equal semantic snapshot differs only in a frequently changing progress field.
        replay.send([
            TaskInfo(.object(["task_id": .string("task"), "status": .string("running"), "workflow_run_id": .null,
                              "duration_seconds": .number(2)]))!
        ])

        // when
        await waitUntil { !sut.loading }
        let initialReads = await source.counts()
        clock.advanceUptime(29)
        await sut.tick()
        let throttledReads = await source.counts()

        // then
        #expect(sut.presentation.status == "Nothing running.")
        #expect(initialReads.0 == 1 && initialReads.1 == 1 && initialReads.2 == 1)
        #expect(throttledReads.0 == initialReads.0)
        #expect(throttledReads.1 == initialReads.1)
        #expect(throttledReads.2 == initialReads.2)
        sut.didDisappear()
    }
}
