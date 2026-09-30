import Combine
import Foundation
@testable import MenuBarFeature
import Mockable
import MonitorCore
import PbRepository
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
        let event = TaskEvent(line: #"{"v": 1, "seq": 0, "task_id": "t1", "kind": "assistant_text", "text": "hi"}"#)!
        let item = Timeline.items(from: [event])[0]
        given(eventStream).current(for: .value("abc123")).willReturn(item)
        let sut = MenuBarViewRepository(eventStreamRepository: eventStream)

        // then
        #expect(sut.current("abc123") == item)
    }

    // MARK: - Install (settled plan, section 5)

    @Test func givenInstallRepositoryValues_whenReadOrActed_thenTheyPassThrough() async {
        // given
        let install = MockInstallRepository()
        given(install).state.willReturn(.needsUv)
        given(install).lastCheckMessage.willReturn("checking")
        given(install).installAnywayBlockedMessage.willReturn("blocked")
        given(install).destination().willReturn("/Users/x/.local/bin")
        given(install).statePublisher().willReturn(Just(InstallState.needsUv).eraseToAnyPublisher())
        given(install).lastCheckMessagePublisher().willReturn(Just("checking").eraseToAnyPublisher())
        given(install).installAnywayBlockedMessagePublisher().willReturn(Just("blocked").eraseToAnyPublisher())
        given(install).install().willReturn()
        given(install).installUvThenPolybridge().willReturn()
        given(install).retry().willReturn()
        given(install).checkAgain().willReturn()
        given(install).installAnyway().willReturn(true)
        given(install).reset().willReturn()
        let sut = MenuBarViewRepository(installRepository: install)

        // then — reads
        #expect(sut.installState == .needsUv)
        #expect(sut.lastCheckMessage == "checking")
        #expect(sut.installAnywayBlockedMessage == "blocked")
        #expect(sut.installDestination() == "/Users/x/.local/bin")

        // when — actions
        await sut.install()
        await sut.installUvThenPolybridge()
        await sut.retry()
        await sut.checkAgain()
        let allowed = await sut.installAnyway()
        sut.reset()

        // then
        #expect(allowed)
        verify(install).install().called(1)
        verify(install).installUvThenPolybridge().called(1)
        verify(install).retry().called(1)
        verify(install).checkAgain().called(1)
        verify(install).installAnyway().called(1)
        verify(install).reset().called(1)
    }

    @Test func givenBothToolsMissing_whenInstallNeedIsComputed_thenTheClassifierSaysMissing() {
        // given — `installNeed(for:)` locates both tools fresh through `ToolEnvironmentRepository`
        // rather than trusting the error's own claim, then hands the classifier both presences.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).locator.willReturn(
            ToolLocator(overrideDirectory: nil, home: "/Users/x", uvToolBin: nil, isExecutable: { _ in false })
        )
        let sut = MenuBarViewRepository(toolEnvironmentRepository: toolEnvironment)

        // when
        let need = sut.installNeed(for: .notFound(tool: "polybridge-setup", searched: []))

        // then
        #expect(need == .missing)
    }
}
