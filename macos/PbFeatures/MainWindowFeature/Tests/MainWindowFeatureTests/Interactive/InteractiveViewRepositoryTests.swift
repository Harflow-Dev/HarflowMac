import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTerminal
import Testing

@MainActor
@Suite struct InteractiveViewRepositoryTests {
    
    @Test func givenSessionsPublisher_whenCalled_thenItForwardsToTheSessionRegistry() {
        // given
        let registry = MockTerminalSessionRegistry()
        let subject = PassthroughSubject<[TerminalSession], Never>()
        given(registry).sessionsPublisher().willReturn(subject.eraseToAnyPublisher())
        let sut = InteractiveViewRepository(terminalSessionRegistry: registry)
        var received: [[TerminalSession]] = []
        let cancellable = sut.sessionsPublisher().sink { received.append($0) }
        
        // when
        subject.send([])
        
        // then
        #expect(received.count == 1)
        #expect(received.first?.isEmpty == true)
        cancellable.cancel()
    }
    
    @Test func givenRemoveSession_whenCalled_thenItForwardsToTheSessionRegistry() throws {
        // given — `TerminalSession` is not `Equatable`, so capture the argument via `willProduce`
        // (same pattern as `NewSessionViewRepositoryTests`) rather than a `.value(_:)` matcher.
        let registry = MockTerminalSessionRegistry()
        var received: TerminalSession?
        given(registry)
            .remove(.any)
            .willProduce { received = $0 }
        let sut = InteractiveViewRepository(terminalSessionRegistry: registry)
        let session = TerminalSession(
            kind: .interactive, title: "t", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        
        // when
        sut.removeSession(session)
        
        // then
        #expect(received === session)
    }
}
