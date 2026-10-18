import Combine
import Foundation
@testable import PbCommon
import PbTestUtilities
import Testing

@MainActor
@Observable
private final class TestViewModel: ViewModel {}

@MainActor
@Suite struct ViewModelPublishTests {
    
    @Test func givenAViewModel_whenPublishingAnAlert_thenSendsAnAlertEvent() async {
        // given
        let vm = TestViewModel()
        var received: ViewEvent?
        let cancellable = vm.objectDidPublishViewEvent.publisher.sink { received = $0 }
        
        // when
        vm.publishAlert("Cancel this task?") {
            AlertAction(title: "Cancel task and its sub-tasks", role: .destructive)
        }
        await waitUntil { received != nil }
        
        // then
        #expect(received?.alert?.title == "Cancel this task?")
        #expect(received?.alert?.actions.first?.role == .destructive)
        cancellable.cancel()
    }
    
    @Test func givenAViewModel_whenPublishingADialog_thenSendsADialogEvent() async {
        // given
        let vm = TestViewModel()
        var received: ViewEvent?
        let cancellable = vm.objectDidPublishViewEvent.publisher.sink { received = $0 }
        
        // when
        vm.publishDialog("Take over this task?", description: "The terminal runs under your own permissions.") {
            AlertAction(title: "Stop it and take over")
            AlertAction(title: "Cancel", role: .cancel)
        }
        await waitUntil { received != nil }
        
        // then
        #expect(received?.dialog?.title == "Take over this task?")
        #expect(received?.dialog?.actions.count == 2)
        #expect(received?.dialog?.actions.last?.role == .cancel)
        cancellable.cancel()
    }
    
    @Test func givenAViewModel_whenFlushingViewEvent_thenSendsNone() async {
        // given
        let vm = TestViewModel()
        var received: ViewEvent?
        let cancellable = vm.objectDidPublishViewEvent.publisher.sink { received = $0 }
        
        // when
        vm.flushViewEvent()
        await waitUntil { received != nil }
        
        // then — spelled out to avoid `Optional<ViewEvent>.none` (nil) shadowing `ViewEvent.none`.
        #expect(received == ViewEvent.none)
        cancellable.cancel()
    }
    
    @Test func givenAViewModel_whenAccessedTwice_thenReturnsTheSamePublisherInstance() {
        // given
        let vm = TestViewModel()
        
        // when
        let first = vm.objectDidPublishViewEvent
        let second = vm.objectDidPublishViewEvent
        
        // then
        #expect(first === second)
    }
}
