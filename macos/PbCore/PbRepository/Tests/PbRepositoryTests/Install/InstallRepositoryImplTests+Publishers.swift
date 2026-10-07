import Combine
import Foundation
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

// MARK: - InstallRepositoryImplTests: publishers

extension InstallRepositoryImplTests {
    @Test func givenValidationMessageSubscriber_whenSameFailureIsRetried_thenStateTransitionsStillArrive() async {
        // given
        let sut = makeSUT(runner: Self.makeRunner(ctlListJSON: #"{"v":99,"tasks":[]}"#))
        let messages = LockedBox<[String?]>([])
        let states = LockedBox<[InstallState]>([])
        let subscriptions = [
            sut.lastCheckMessagePublisher().sink { value in messages.mutate { $0.append(value) } },
            sut.statePublisher().sink { value in states.mutate { $0.append(value) } }
        ]
        // when
        await sut.install()
        let failure = sut.state
        await sut.checkAgain()
        await sut.checkAgain()
        // then
        #expect(messages.value.count == 2)
        #expect(messages.value.first.flatMap(\.self) == nil)
        #expect(messages.value.last.flatMap(\.self) != nil)
        #expect(states.value.suffix(4) == [.running(.validate), failure, .running(.validate), failure])
        #expect(states.value.first == .idle)
        withExtendedLifetime(subscriptions) {}
    }

    @Test func givenBlockedInstallSubscriber_whenSameBlockRepeats_thenOnlyOneBlockMessageArrives() async {
        // given
        let runner = Self.makeRunner(pgrepExitCode: 0) { call in
            call.executable == Self.uvExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true)) : nil
        }
        let sut = makeSUT(runner: runner)
        let messages = LockedBox<[String?]>([])
        let token = sut.installAnywayBlockedMessagePublisher().sink { value in messages.mutate { $0.append(value) } }
        // when
        await sut.install()
        #expect(await sut.installAnyway() == false)
        #expect(await sut.installAnyway() == false)
        // then
        #expect(messages.value.count == 2)
        #expect(messages.value.first.flatMap(\.self) == nil)
        #expect(messages.value.last.flatMap(\.self) != nil)
        #expect(sut.state == .unresolved(stage: .polybridge))
        withExtendedLifetime(token) {}
    }

}
