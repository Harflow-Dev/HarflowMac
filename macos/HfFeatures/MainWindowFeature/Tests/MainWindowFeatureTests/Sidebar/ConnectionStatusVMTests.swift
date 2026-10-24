import Combine
import HfCommon
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct ConnectionStatusVMTests {
    @Test func givenNoSuccessfulListing_whenInitialized_thenItShowsDisconnectedAndConnectionHint() {
        // given
        let harness = makeHarness(hasListed: false, connectionLine: "connecting…")

        // when
        let sut = ConnectionStatusVM(useCase: harness.useCase)

        // then
        #expect(sut.isConnected == false)
        #expect(sut.helpText == "connecting…")
    }

    @Test func givenAListingAndNoError_whenPublished_thenItShowsConnectedAndKeepsConnectionHint() async {
        // given
        let harness = makeHarness(connectionLine: "connected · harflow-ctl")
        let sut = ConnectionStatusVM(useCase: harness.useCase)
        sut.didAppear()

        // when
        harness.hasListed.send(true)
        harness.listError.send(nil)
        harness.tasks.send([])

        // then
        await waitUntil { sut.isConnected }
        #expect(sut.helpText == "connected · harflow-ctl")
    }

    @Test func givenAConnectedStatus_whenListingFails_thenItShowsDisconnectedAndTheErrorHint() async {
        // given
        let harness = makeHarness(connectionLine: "connected · harflow-ctl")
        let sut = ConnectionStatusVM(useCase: harness.useCase)
        sut.didAppear()
        harness.hasListed.send(true)
        harness.listError.send(nil)
        await waitUntil { sut.isConnected }
        let error = ToolError.refused(code: "denied", message: "harflow-ctl refused the request.")

        // when
        harness.listError.send(error)

        // then
        await waitUntil { !sut.isConnected }
        #expect(sut.helpText == error.message)
    }

    @Test func givenAnErrorStatus_whenTheErrorClears_thenItReconnectsWithoutReappearing() async {
        // given
        let harness = makeHarness(connectionLine: "connecting…")
        let sut = ConnectionStatusVM(useCase: harness.useCase)
        sut.didAppear()
        harness.hasListed.send(true)
        let error = ToolError.refused(code: "denied", message: "temporary failure")
        harness.listError.send(error)
        await waitUntil { sut.helpText == error.message }
        #expect(!sut.isConnected)

        // when
        harness.listError.send(nil)

        // then
        await waitUntil { sut.isConnected }
        #expect(sut.helpText == "connecting…")
    }

    @Test func givenAVisibleStatus_whenDisappearing_thenPublishersStopUntilItAppearsAgain() async {
        // given
        let harness = makeHarness(connectionLine: "connected · harflow-ctl")
        let sut = ConnectionStatusVM(useCase: harness.useCase)
        sut.didAppear()
        harness.hasListed.send(true)
        await waitUntil { sut.isConnected }
        sut.didDisappear()

        // when — this event arrives while the indicator is not mounted.
        harness.listError.send(ToolError.refused(code: "denied", message: "offline"))

        // then — no stale subscription changes the detached indicator.
        #expect(sut.isConnected)
        #expect(sut.helpText == "connected · harflow-ctl")

        // when — reappearance takes a fresh subscription and reflects current state.
        sut.didAppear()
        let reappearedError = ToolError.refused(code: "denied", message: "offline")
        harness.listError.send(reappearedError)

        // then
        await waitUntil { sut.helpText == reappearedError.message }
        #expect(!sut.isConnected)
        #expect(sut.helpText == reappearedError.message)
    }

    private struct Harness {
        let useCase: MockSidebarUseCase
        let tasks: PassthroughSubject<[TaskInfo], Never>
        let listError: PassthroughSubject<ToolError?, Never>
        let hasListed: PassthroughSubject<Bool, Never>
    }

    private func makeHarness(hasListed initialHasListed: Bool = false, connectionLine: String) -> Harness {
        let useCase = MockSidebarUseCase()
        let tasks = PassthroughSubject<[TaskInfo], Never>()
        let listError = PassthroughSubject<ToolError?, Never>()
        let hasListed = PassthroughSubject<Bool, Never>()
        given(useCase).connectionLine.willReturn(connectionLine)
        given(useCase).hasListed.willReturn(initialHasListed)
        given(useCase).listError.willReturn(nil)
        given(useCase).tasks.willReturn([])
        given(useCase).tasksPublisher().willReturn(tasks.eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(listError.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(hasListed.eraseToAnyPublisher())
        return Harness(useCase: useCase, tasks: tasks, listError: listError, hasListed: hasListed)
    }
}
