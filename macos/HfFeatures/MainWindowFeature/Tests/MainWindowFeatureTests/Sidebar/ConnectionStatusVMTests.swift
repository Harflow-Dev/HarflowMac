import Combine
import Foundation
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

    @Test func givenOverlappingAppearances_whenOneDisappears_thenReadinessAndErrorRecoveryRemainSubscribedUntilTheLastDisappearance() async {
        // given — two hosts own the same VM and its three replaying publisher pipelines.
        let harness = makeReplayingHarness()
        let sut = ConnectionStatusVM(useCase: harness.useCase)
        sut.didAppear()
        sut.didAppear()
        #expect(harness.subscriptions.count(for: .hasListed).subscriptions == 1)
        #expect(harness.subscriptions.count(for: .listError).subscriptions == 1)
        #expect(harness.subscriptions.count(for: .tasks).subscriptions == 1)

        // when — one host disappears while the other still owns the VM.
        sut.didDisappear()

        // then — the shared subscriptions remain active and the remaining owner receives readiness.
        #expect(harness.subscriptions.count(for: .hasListed).cancellations == 0)
        #expect(harness.subscriptions.count(for: .listError).cancellations == 0)
        #expect(harness.subscriptions.count(for: .tasks).cancellations == 0)
        harness.hasListed.send(true)
        await waitUntil(timeout: 2) { sut.isConnected }
        #expect(sut.isConnected)

        // when — an error and its recovery arrive while one appearance owner remains.
        let error = ToolError.refused(code: "denied", message: "temporary failure")
        harness.listError.send(error)
        await waitUntil(timeout: 2) { sut.helpText == error.message }

        // then — error state is truthful and clears without requiring a new appearance.
        #expect(!sut.isConnected)
        #expect(sut.helpText == error.message)
        harness.listError.send(nil)
        await waitUntil(timeout: 2) { sut.isConnected }
        #expect(sut.isConnected)

        // when — the last owner disappears, followed by a harmless extra disappearance.
        sut.didDisappear()
        sut.didDisappear()

        // then — each of the three pipelines cancels exactly once.
        #expect(harness.subscriptions.count(for: .hasListed).cancellations == 1)
        #expect(harness.subscriptions.count(for: .listError).cancellations == 1)
        #expect(harness.subscriptions.count(for: .tasks).cancellations == 1)
    }

    @Test func givenReplayingStatus_whenVMReappears_thenItReceivesCurrentErrorAndReadinessAndCancelsAgain() async {
        // given — one appearance subscribes, becomes connected, then observes a failure.
        let harness = makeReplayingHarness()
        let sut = ConnectionStatusVM(useCase: harness.useCase)
        sut.didAppear()
        harness.hasListed.send(true)
        await waitUntil(timeout: 2) { sut.isConnected }
        let initialError = ToolError.refused(code: "denied", message: "first failure")
        harness.listError.send(initialError)
        await waitUntil(timeout: 2) { sut.helpText == initialError.message }
        sut.didDisappear()

        // when — a newer error becomes current while detached, then the VM appears again.
        let replayedError = ToolError.refused(code: "denied", message: "replayed failure")
        harness.listError.send(replayedError)
        #expect(sut.helpText == initialError.message)

        // An unmatched disappearance after teardown cannot make the next appearance undercount owners.
        sut.didDisappear()
        #expect(harness.subscriptions.count(for: .hasListed).cancellations == 1)
        sut.didAppear()

        // then — the second subscription replays current readiness and error, then recovers live.
        await waitUntil(timeout: 2) { sut.helpText == replayedError.message }
        #expect(!sut.isConnected)
        #expect(sut.helpText == replayedError.message)
        #expect(harness.subscriptions.count(for: .hasListed).subscriptions == 2)
        #expect(harness.subscriptions.count(for: .listError).subscriptions == 2)
        #expect(harness.subscriptions.count(for: .tasks).subscriptions == 2)
        #expect(harness.subscriptions.count(for: .hasListed).cancellations == 1)
        #expect(harness.subscriptions.count(for: .listError).cancellations == 1)
        #expect(harness.subscriptions.count(for: .tasks).cancellations == 1)

        harness.listError.send(nil)
        await waitUntil(timeout: 2) { sut.isConnected }
        #expect(sut.isConnected)
        sut.didDisappear()
        #expect(harness.subscriptions.count(for: .hasListed).cancellations == 2)
        #expect(harness.subscriptions.count(for: .listError).cancellations == 2)
        #expect(harness.subscriptions.count(for: .tasks).cancellations == 2)
    }

    private enum PublisherChannel: String, Hashable, Sendable {
        case hasListed
        case listError
        case tasks
    }

    private struct PublisherCounts {
        var subscriptions = 0
        var cancellations = 0
    }

    private final class SubscriptionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PublisherChannel: PublisherCounts] = [:]

        func recordSubscription(_ channel: PublisherChannel) {
            lock.lock()
            defer { lock.unlock() }
            values[channel, default: PublisherCounts()].subscriptions += 1
        }

        func recordCancellation(_ channel: PublisherChannel) {
            lock.lock()
            defer { lock.unlock() }
            values[channel, default: PublisherCounts()].cancellations += 1
        }

        func count(for channel: PublisherChannel) -> PublisherCounts {
            lock.lock()
            defer { lock.unlock() }
            return values[channel, default: PublisherCounts()]
        }
    }

    private struct ReplayingHarness {
        let useCase: MockSidebarUseCase
        let hasListed: CurrentValueSubject<Bool, Never>
        let listError: CurrentValueSubject<ToolError?, Never>
        let tasks: CurrentValueSubject<[TaskInfo], Never>
        let subscriptions: SubscriptionProbe
    }

    private func makeReplayingHarness() -> ReplayingHarness {
        let useCase = MockSidebarUseCase()
        let hasListed = CurrentValueSubject<Bool, Never>(false)
        let listError = CurrentValueSubject<ToolError?, Never>(nil)
        let tasks = CurrentValueSubject<[TaskInfo], Never>([])
        let subscriptions = SubscriptionProbe()
        given(useCase).connectionLine.willReturn("connecting…")
        given(useCase).hasListed.willReturn(false)
        given(useCase).listError.willReturn(nil)
        given(useCase).tasks.willReturn([])
        let hasListedPublisher = hasListed
            .handleEvents(
                receiveSubscription: { _ in subscriptions.recordSubscription(.hasListed) },
                receiveCancel: { subscriptions.recordCancellation(.hasListed) }
            )
            .eraseToAnyPublisher()
        let listErrorPublisher = listError
            .handleEvents(
                receiveSubscription: { _ in subscriptions.recordSubscription(.listError) },
                receiveCancel: { subscriptions.recordCancellation(.listError) }
            )
            .eraseToAnyPublisher()
        let tasksPublisher = tasks
            .handleEvents(
                receiveSubscription: { _ in subscriptions.recordSubscription(.tasks) },
                receiveCancel: { subscriptions.recordCancellation(.tasks) }
            )
            .eraseToAnyPublisher()
        given(useCase).hasListedPublisher().willReturn(hasListedPublisher)
        given(useCase).listErrorPublisher().willReturn(listErrorPublisher)
        given(useCase).tasksPublisher().willReturn(tasksPublisher)
        return ReplayingHarness(
            useCase: useCase,
            hasListed: hasListed,
            listError: listError,
            tasks: tasks,
            subscriptions: subscriptions
        )
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
