@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TimelineRowTests

@Suite struct TimelineRowTests {

    @Test func givenACleanCompletion_whenBuildingTheFinishedText_thenItReadsJustFinished() {
        // given / when / then
        #expect(TimelineRow.finishedText(status: .completed, exitCode: 0) == "Finished")
        #expect(TimelineRow.finishedText(status: .completed, exitCode: nil) == "Finished")
    }

    @Test func givenANonZeroExit_whenBuildingTheFinishedText_thenItShowsTheStatusAndExitCode() {
        // given / when / then
        #expect(TimelineRow.finishedText(status: .failed, exitCode: 1) == "Failed · exit 1")
        #expect(TimelineRow.finishedText(status: .cancelled, exitCode: -15) == "Cancelled · exit -15")
    }

    @Test func givenAFailureWithNoObservedExit_whenBuildingTheFinishedText_thenItIsTheStatusAlone() {
        // given / when / then
        #expect(TimelineRow.finishedText(status: .timedOut, exitCode: nil) == "Timed out")
    }
}
