import Foundation
import MonitorCore
@testable import PbTerminal
import PbTestUtilities
import Testing

@MainActor
@Suite(.serialized)
struct TerminalSessionTests {

    // MARK: frame + font (F4-48 — the testable half; first-responder reparenting is manual)

    @Test func givenAFrameAndFont_whenTheTerminalViewIsCreated_thenTheyAre900x560AndMonospaced12() throws {
        // given / when — never call `start()`: this only inspects what `init` configured.
        let session = TerminalSession(kind: .interactive, title: "t", backend: "claude", command: try blockingCommand())

        // then
        #expect(session.view.frame.width == 900)
        #expect(session.view.frame.height == 560)
        #expect(session.view.font.pointSize == 12)
        #expect(session.view.font.fontName.lowercased().contains("mono"))
    }

    // MARK: leader already exited (MS-TERM-2 — `.alreadyGone`)

    @Test func givenTheLeaderAlreadyExited_whenTerminated_thenItCompletesAlreadyGone() async throws {
        // given
        let session = TerminalSession(kind: .interactive, title: "t", backend: "claude", command: try fastExitingCommand())
        session.start()
        await waitUntil { session.ended }

        // when
        let outcome = await withCheckedContinuation { continuation in
            session.terminate { continuation.resume(returning: $0) }
        }

        // then
        #expect(outcome == .alreadyGone)
    }

    // MARK: onEnded fires once (MS-TERM-3)

    @Test func givenTheSessionAlreadyEnded_whenTerminatedAgain_thenOnEndedDoesNotFireASecondTime() async throws {
        // given
        let session = TerminalSession(kind: .interactive, title: "t", backend: "claude", command: try fastExitingCommand())
        var endedCount = 0
        session.onEnded = { endedCount += 1 }
        session.start()
        await waitUntil { session.ended }
        #expect(endedCount == 1)

        // when — terminate again, after the session already ended naturally.
        _ = await withCheckedContinuation { continuation in
            session.terminate { continuation.resume(returning: $0) }
        }

        // then
        #expect(endedCount == 1)
    }

    // MARK: terminate joins an in-flight terminate (MS-TERM-2)

    @Test func givenATerminateAlreadyInFlight_whenTerminateIsCalledAgain_thenTheSecondCallerJoinsTheFirstAndSeesTheSameOutcome() async throws {
        // given — /bin/cat blocks, so the first terminate() has real work to do (SIGHUP/SIGTERM,
        // wait for the grace period) while the second call joins it.
        let session = TerminalSession(kind: .interactive, title: "t", backend: "claude", command: try blockingCommand())
        session.start()
        await waitUntil { session.pid != nil }

        // when — both calls are synchronous (they only dispatch work in the background), so calling
        // them back to back on the main actor is what "already in flight" means here: the second
        // call's `terminating` check sees the first call's flag before its background work returns.
        var firstOutcome: ChildReaper.Outcome?
        var secondOutcome: ChildReaper.Outcome?
        session.terminate { firstOutcome = $0 }
        session.terminate { secondOutcome = $0 }
        await waitUntil(timeout: 8) { firstOutcome != nil && secondOutcome != nil }

        // then — both callers were told the same outcome, and the session ended exactly once.
        #expect(firstOutcome == secondOutcome)
        #expect(session.ended)
    }
}
