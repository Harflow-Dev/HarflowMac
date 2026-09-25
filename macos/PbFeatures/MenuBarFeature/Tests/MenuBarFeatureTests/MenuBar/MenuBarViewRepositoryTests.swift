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
        let settings = MockSettingsRepository()
        given(taskList).connectionLine.willReturn("connected")
        given(taskList).runningCount.willReturn(2)
        given(settings).openWindowOnStart.willReturn(false)
        given(settings).notifyOnFinish.willReturn(false)
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        let sut = MenuBarViewRepository(taskListRepository: taskList, settingsRepository: settings)
        
        // then
        #expect(sut.connectionLine == "connected")
        #expect(sut.runningCount == 2)
        #expect(sut.openWindowOnStart == false)
        #expect(sut.notifyOnFinish == false)
        #expect(sut.title("abc123") == "Fix the bug")
    }
    
    @Test func givenSetters_whenCalled_thenTheyForwardToSettingsRepository() {
        // given
        let settings = MockSettingsRepository()
        given(settings).setOpenWindowOnStart(.value(false)).willReturn()
        given(settings).setNotifyOnFinish(.value(false)).willReturn()
        let sut = MenuBarViewRepository(settingsRepository: settings)
        
        // when
        sut.setOpenWindowOnStart(false)
        sut.setNotifyOnFinish(false)
        
        // then
        verify(settings).setOpenWindowOnStart(.value(false)).called(1)
        verify(settings).setNotifyOnFinish(.value(false)).called(1)
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
}
