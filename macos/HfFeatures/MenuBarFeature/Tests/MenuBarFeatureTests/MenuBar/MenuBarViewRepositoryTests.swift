import Combine
import Foundation
import HfRepository
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct MenuBarViewRepositoryTests {
    
    @Test func givenTheProperties_whenRead_thenTheyPassThroughToTheRepositories() {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).connectionLine.willReturn("connected")
        given(taskList).runningCount.willReturn(2)
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        let sut = MenuBarViewRepository(taskListRepository: taskList)
        
        // then
        #expect(sut.connectionLine == "connected")
        #expect(sut.runningCount == 2)
        #expect(sut.title("abc123") == "Fix the bug")
    }
    
    @Test func givenSetupState_whenRead_thenRuntimeReadyMapsFromIt() {
        // given
        let install = MockInstallRepository()
        given(install).setupState.willReturn(.ready)
        let sut = MenuBarViewRepository(installRepository: install)

        // then
        #expect(sut.runtimeReady)
    }

    @Test func givenARuntimeThatIsNotReady_whenRead_thenRuntimeReadyIsFalse() {
        // given
        let install = MockInstallRepository()
        given(install).setupState.willReturn(.checking)
        let sut = MenuBarViewRepository(installRepository: install)

        // then
        #expect(sut.runtimeReady == false)
    }

    /// Built outside the main actor so the sink closure is not main-actor isolated and may receive off the main thread.
    private nonisolated static func collect(_ publisher: AnyPublisher<Bool, Never>, into box: LockedBox<[Bool]>) -> AnyCancellable {
        publisher.sink { value in box.mutate { $0.append(value) } }
    }

    @Test func givenSetupStatesFromABackgroundQueue_whenMappedToReadiness_thenDuplicatesAreDroppedWithoutTrapping() async {
        // given
        let subject = PassthroughSubject<RuntimeSetupState, Never>()
        let received = LockedBox<[Bool]>([])
        let token = Self.collect(MenuBarViewRepository.readiness(subject.eraseToAnyPublisher()), into: received)

        // when
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                subject.send(.checking)
                subject.send(.ready)
                subject.send(.ready)
                subject.send(.checking)
                continuation.resume()
            }
        }

        // then
        #expect(received.value == [false, true, false])
        withExtendedLifetime(token) {}
    }

    @Test func givenAcquireEventLease_whenCalled_thenItPassesThroughToEventStreamRepository() {
        // given
        let eventStream = MockEventStreamRepository()
        let lease = MockEventStreamLease()
        given(eventStream).acquire(.value("abc123")).willReturn(lease)
        let sut = MenuBarViewRepository(eventStreamRepository: eventStream)
        
        // when
        let result = sut.acquireEventLease("abc123")
        
        // then
        #expect(result === lease)
    }
    
    @Test func givenCurrent_whenCalled_thenItPassesThroughToEventStreamRepository() {
        // given — `TimelineItem` has no public initializer, built via the public `TaskEvent(line:)`
        // decoder and `Timeline.items(from:)`.
        let eventStream = MockEventStreamRepository()
        let event = TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":0,"task_id":"t1","kind":"assistant_text","text":"hi"}"#)!
        let item = Timeline.items(from: [event])[0]
        given(eventStream).current(for: .value("abc123")).willReturn(item)
        let sut = MenuBarViewRepository(eventStreamRepository: eventStream)

        // then
        #expect(sut.current("abc123") == item)
    }

    // MARK: - Install

    @Test func givenInstallRepositoryValues_whenReadOrActed_thenTheyPassThrough() async {
        // given
        let install = MockInstallRepository()
        given(install).state.willReturn(.running(.harflow))
        given(install).lastCheckMessage.willReturn("checking")
        given(install).statePublisher().willReturn(Just(InstallState.running(.harflow)).eraseToAnyPublisher())
        given(install).lastCheckMessagePublisher().willReturn(Just("checking").eraseToAnyPublisher())
        given(install).retry().willReturn()
        given(install).reset().willReturn()
        let sut = MenuBarViewRepository(installRepository: install)

        // then — reads
        #expect(sut.installState == .running(.harflow))
        #expect(sut.lastCheckMessage == "checking")

        // when — actions
        await sut.retry()
        sut.reset()

        // then
        verify(install).retry().called(1)
        verify(install).reset().called(1)
    }
}
