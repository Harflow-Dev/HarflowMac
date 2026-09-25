import Foundation
import MonitorCore
@testable import PbTerminal
import PbTestUtilities
import Testing

@MainActor
@Suite(.serialized)
struct TerminalSessionRegistryImplTests {

    private func makeSUT() -> TerminalSessionRegistryImpl { TerminalSessionRegistryImpl() }

    // MARK: session(forTask:) — F4-20, "the latest takeover session wins"

    @Test func givenTwoSessionsForTheSameTask_whenLookedUp_thenTheMostRecentOneIsReturned() throws {
        // given
        let sut = makeSUT()
        let first = TerminalSession(kind: .takeover(taskID: "t1"), title: "first", backend: "claude", command: try blockingCommand())
        let second = TerminalSession(kind: .takeover(taskID: "t1"), title: "second", backend: "claude", command: try blockingCommand())
        sut.add(first)
        sut.add(second)

        // when
        let found = sut.session(forTask: "t1")

        // then
        #expect(found === second)
    }

    @Test func givenNoSessionForTheTask_whenLookedUp_thenNilIsReturned() throws {
        // given — a session for a *different* task exists and was really added, proving the lookup
        // filters by id rather than trivially returning nil regardless of what is registered.
        let sut = makeSUT()
        let other = TerminalSession(kind: .takeover(taskID: "other"), title: "t", backend: "claude", command: try blockingCommand())
        sut.add(other)
        #expect(sut.sessions.contains { $0 === other })

        // when / then
        #expect(sut.session(forTask: "missing") == nil)
    }

    // MARK: interactiveSessions — F4-22

    @Test func givenAnEndedInteractiveSession_whenListingInteractiveSessions_thenItIsExcluded() async throws {
        // given
        let sut = makeSUT()
        let session = TerminalSession(kind: .interactive, title: "claude · repo", backend: "claude", command: try fastExitingCommand())
        sut.add(session)
        session.start()
        await waitUntil { session.ended }

        // when / then
        #expect(sut.interactiveSessions.isEmpty)
        #expect(sut.sessions.contains { $0 === session })
    }

    @Test func givenATakeoverSession_whenListingInteractiveSessions_thenItIsExcludedRegardlessOfEndedState() throws {
        // given
        let sut = makeSUT()
        let session = TerminalSession(kind: .takeover(taskID: "t1"), title: "t", backend: "claude", command: try blockingCommand())
        sut.add(session)
        // The session was really added (rules out a no-op `add` that would also leave
        // `interactiveSessions` trivially empty below).
        #expect(sut.sessions.contains { $0 === session })

        // when / then
        #expect(sut.interactiveSessions.isEmpty)
    }

    // MARK: remove — F4-22, terminate then remove immediately without waiting

    @Test func givenRemoveSession_whenCalled_thenItIsRemovedImmediatelyWithoutWaitingForTheOutcome() throws {
        // given
        let sut = makeSUT()
        let session = TerminalSession(kind: .takeover(taskID: "t1"), title: "t", backend: "claude", command: try blockingCommand())
        sut.add(session)
        #expect(sut.sessions.count == 1)

        // when
        sut.remove(session)

        // then — removed synchronously, even though `terminate()`'s own completion has not run yet.
        #expect(sut.sessions.isEmpty)
    }

    // MARK: endedSessionsPublisher

    @Test func givenASessionEnds_whenObserved_thenTheEndedSessionsPublisherFiresOnceWithThatSession() async throws {
        // given
        let sut = makeSUT()
        let session = TerminalSession(kind: .interactive, title: "t", backend: "claude", command: try fastExitingCommand())
        var received: [TerminalSession] = []
        let cancellable = sut.endedSessionsPublisher().sink { received.append($0) }
        sut.add(session)

        // when
        session.start()
        await waitUntil { !received.isEmpty }

        // then
        #expect(received.count == 1)
        #expect(received.first === session)
        cancellable.cancel()
    }

    // MARK: startInteractive (F4-21)

    @Test func givenAnInteractiveStartSucceeds_whenObserved_thenTheSessionIsAppendedBeforeItIsStartedWithTheExactTitle() async {
        // given
        let sut = makeSUT()

        // when — "cat" blocks on stdin, so it stays alive long enough to assert against.
        let result = sut.startInteractive(backend: "cat", repo: "/tmp", environment: [:])

        // then
        guard case .success(let session) = result else { Issue.record("expected success"); return }
        #expect(session.title == "cat · /tmp")
        #expect(sut.sessions.contains { $0 === session })
        await waitUntil { session.pid != nil }

        // cleanup
        await withCheckedContinuation { continuation in session.terminate { _ in continuation.resume() } }
    }

    @Test func givenAnInteractiveStartFails_whenObserved_thenTheExactErrorTextIsReturnedAndNothingIsAppended() {
        // given — an uppercase backend name fails `InteractiveSession.command`'s regex guard, with no
        // process ever spawned.
        let sut = makeSUT()

        // when
        let result = sut.startInteractive(backend: "NOT_VALID", repo: "/tmp", environment: [:])

        // then
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.message.hasPrefix("Could not start NOT_VALID: "))
        #expect(sut.sessions.isEmpty)
    }
}
