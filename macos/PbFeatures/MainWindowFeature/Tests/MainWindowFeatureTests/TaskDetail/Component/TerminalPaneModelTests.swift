@testable import MainWindowFeature
import MonitorCore
import PbTerminal
import Testing

/// F4-49/MS-TERM-4: the reservation text rule, on primitives (a live `TerminalSession` cannot have
/// its `ended`/`attached`/`attachError` set arbitrarily from a test — they are `private(set)`/
/// `internal(set)` outside `PbTerminal`).
@Suite struct TerminalPaneModelTests {
    
    @Test func givenAnEndedSession_whenAttachedWasNeverTrue_thenTheReservationTextIsNeverShown() {
        // given / when
        let result = TerminalPaneModel.reservationText(kind: .takeover(taskID: "abc123"), ended: true, attached: false, hasAttachError: true)
        
        // then — "ended", never "ended · reservation released" (that text implies a released
        // reservation, which only ever follows a session that really was attached).
        #expect(result?.text == "ended")
    }
    
    @Test func givenAnEndedSessionThatWasAttached_whenRendered_thenTheReservationIsReportedReleased() {
        // given / when
        let result = TerminalPaneModel.reservationText(kind: .takeover(taskID: "abc123"), ended: true, attached: true, hasAttachError: false)
        
        // then
        #expect(result?.text == "ended · reservation released")
        #expect(result?.isGreen == false)
    }
    
    @Test func givenALiveAttachedSession_whenRendered_thenItReportsReservedInGreen() {
        // given / when
        let result = TerminalPaneModel.reservationText(kind: .takeover(taskID: "abc123"), ended: false, attached: true, hasAttachError: false)
        
        // then
        #expect(result?.text == "session reserved")
        #expect(result?.isGreen == true)
    }
    
    @Test func givenALiveUnattachedSessionWithNoErrorYet_whenRendered_thenItReportsAttaching() {
        // given / when
        let result = TerminalPaneModel.reservationText(kind: .takeover(taskID: "abc123"), ended: false, attached: false, hasAttachError: false)
        
        // then
        #expect(result?.text == "attaching…")
        #expect(result?.isGreen == false)
    }
    
    @Test func givenALiveUnattachedSessionWithAnError_whenRendered_thenItReportsNotAttached() {
        // given / when
        let result = TerminalPaneModel.reservationText(kind: .takeover(taskID: "abc123"), ended: false, attached: false, hasAttachError: true)
        
        // then
        #expect(result?.text == "not attached")
    }
    
    @Test func givenAnInteractiveSession_whenRendered_thenNoReservationTextAppearsAtAll() {
        // given / when
        let result = TerminalPaneModel.reservationText(kind: .interactive, ended: false, attached: false, hasAttachError: false)
        
        // then — interactive sessions never reserve anything.
        #expect(result == nil)
    }
    
    // MARK: - Item s: `.build(from:)` reflects the session's live state
    
    @MainActor
    @Test func givenAFreshSession_whenBuildingTheModel_thenItIsNeitherEndedNorTerminatingAndHasNoPid() throws {
        // given
        let session = TerminalSession(
            kind: .takeover(taskID: "abc123"), title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        
        // when
        let model = TerminalPaneModel.build(from: session)
        
        // then
        #expect(model.isEnded == false)
        #expect(model.isTerminating == false)
        #expect(model.pidLabel == nil)
        #expect(model.reservationText == "attaching…")
    }
    
    @MainActor
    @Test func givenAStartedSession_whenBuildingTheModel_thenThePidLabelReflectsTheLiveProcess() throws {
        // given
        let session = TerminalSession(
            kind: .takeover(taskID: "abc123"), title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        
        // when
        session.start()
        let model = TerminalPaneModel.build(from: session)
        
        // then
        #expect(model.pidLabel?.hasPrefix("pid ") == true)
    }
}
