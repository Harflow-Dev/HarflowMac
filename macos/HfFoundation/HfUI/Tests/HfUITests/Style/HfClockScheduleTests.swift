import Foundation
@testable import HfUI
import SwiftUI
import Testing

// MARK: - HfClockScheduleTests

struct HfClockScheduleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func givenPausedSchedule_whenQueried_thenProducesNoEntries() {
        // given
        let schedule = HfClockSchedule(every: 1, paused: true)

        // when
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(5))

        // then
        #expect(entries.isEmpty)
    }

    @Test func givenRunningSchedule_whenQueried_thenProducesTheStartThenOneEntryPerInterval() {
        // given
        let schedule = HfClockSchedule(every: 1, paused: false)

        // when
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(3))

        // then
        #expect(entries == [start, start.addingTimeInterval(1), start.addingTimeInterval(2)])
    }

    @Test func givenOccludedThenShownWindow_whenVisibilityReturns_thenScheduleProducesAFreshEntryImmediately() {
        // given — the clock stopped while the window was hidden
        let hidden = HfClockSchedule(every: 1, paused: true)
        #expect(Array(hidden.entries(from: start, mode: .normal).prefix(1)).isEmpty)
        let later = start.addingTimeInterval(3600)

        // when — the window is shown an hour later and the schedule is asked from that moment
        let shown = HfClockSchedule(every: 1, paused: false)
        let first = Array(shown.entries(from: later, mode: .normal).prefix(1)).first

        // then — the first entry is the moment itself, not the next period boundary
        #expect(first == later)
    }

    @Test func givenMinuteSchedule_whenQueried_thenEntriesAreSixtySecondsApart() {
        // given
        let schedule = HfClockSchedule(every: 60, paused: false)

        // when
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(2))

        // then
        #expect(entries[1].timeIntervalSince(entries[0]) == 60)
    }

    @Test func givenSecondAndMinuteFactories_whenBuilt_thenTheyCarryTheirIntervalAndPausedFlag() {
        // given / when
        let second: HfClockSchedule = .hfSecond(paused: true)
        let minute: HfClockSchedule = .hfMinute(paused: false)

        // then
        #expect(second == HfClockSchedule(every: 1, paused: true))
        #expect(minute == HfClockSchedule(every: 60, paused: false))
    }

    @Test func givenNoValueSet_whenMotionPausedIsRead_thenItDefaultsToRunning() {
        // given
        let environment = EnvironmentValues()

        // when / then
        #expect(environment.hfMotionPaused == false)
    }
}
