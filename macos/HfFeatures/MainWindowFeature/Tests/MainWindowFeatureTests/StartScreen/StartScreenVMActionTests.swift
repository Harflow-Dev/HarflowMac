import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - StartScreenVMActionTests

@MainActor
@Suite struct StartScreenVMActionTests {
    private func makeSUT() -> (StartScreenVM, MockStartScreenRouting) {
        let useCase = MockStartScreenUseCase()
        let routing = MockStartScreenRouting()
        let source = FakeStartScreenHistorySource()
        given(useCase).source.willReturn(source)
        given(useCase).changes().willReturn(Empty(completeImmediately: false).eraseToAnyPublisher())
        given(useCase).errors().willReturn(Just(nil).eraseToAnyPublisher())
        given(useCase).historyState().willReturn(Just(HistoryLoadingState()).eraseToAnyPublisher())
        given(routing).openNewSession().willReturn()
        given(routing).openWorkflowEditor(name: .any).willReturn()
        given(routing).openWorkflowRunner(name: .any).willReturn()
        return (StartScreenVM(useCase: useCase, routing: routing), routing)
    }

    @Test func givenStartScreen_whenActionsAreChosen_thenRoutesToTheMatchingDestinations() {
        // given
        let (sut, routing) = makeSUT()

        // when
        sut.newSession()
        sut.newWorkflow()
        sut.showAll()
        sut.run(name: "Saved workflow")

        // then
        verify(routing).openNewSession().called(1)
        verify(routing).openWorkflowEditor(name: .value(nil)).called(1)
        verify(routing).openWorkflowRunner(name: .value(nil)).called(1)
        verify(routing).openWorkflowRunner(name: .value("Saved workflow")).called(1)
    }
}
