import Combine
import HfRepository
@testable import MainWindowFeature
import Mockable
import Testing

@MainActor
extension SidebarVMTests {
    func stubAppearance(_ useCase: MockSidebarUseCase) {
        given(useCase).appAppearance.willReturn(.system)
        given(useCase).appAppearancePublisher().willReturn(Just(.system).eraseToAnyPublisher())
        given(useCase).setAppAppearance(.any).willReturn()
    }

    @Test func givenSidebarAppearanceControlSelection_whenSelected_thenUseCasePersistsAndViewModelUpdates() {
        // given
        let harness = makeSUT()
        #expect(harness.sut.appAppearance == .system)

        // when
        harness.sut.didSelectAppearance(.dark)

        // then
        #expect(harness.sut.appAppearance == .dark)
        verify(harness.useCase).setAppAppearance(.value(.dark)).called(1)
    }
}
