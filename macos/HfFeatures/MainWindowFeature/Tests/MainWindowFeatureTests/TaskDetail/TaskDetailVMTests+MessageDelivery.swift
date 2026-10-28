import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

// MARK: - TaskDetailVM message delivery

extension TaskDetailVMTests {
    @Test func givenSettledTask_whenSendingNow_thenRequestsImmediateDeliveryWithExactText() async {
        // given
        let harness = makeSUT()
        let settled = task(status: "completed")
        harness.detailBox.value = settled
        given(harness.useCase).sendNow(.any, text: .any).willReturn()
        harness.sut.didAppear()
        harness.tasksSubject.send([settled])
        await waitUntil { harness.sut.task != nil }
        // when
        #expect(harness.sut.submitMessageNow("  preserve my text  "))
        // then
        await verify(harness.useCase)
.sendNow(.value("abc12345"), text: .value("  preserve my text  "))
            .calledEventually(1, before: .seconds(5))
        verify(harness.useCase).send(.any, text: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenTakenOverTask_whenSendingNow_thenKeepsTheDraftAndDoesNotDispatch() async {
        // given
        let harness = makeSUT()
        let takenOver = task(status: "running", takenOver: true)
        harness.detailBox.value = takenOver
        harness.sut.didAppear()
        harness.tasksSubject.send([takenOver])
        await waitUntil { harness.sut.task != nil }
        // when / then
        #expect(!harness.sut.submitMessageNow("Keep this draft"))
        verify(harness.useCase).sendNow(.any, text: .any).called(0)
        harness.sut.didDisappear()
    }
}
