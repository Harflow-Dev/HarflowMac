import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

@MainActor
@Suite struct MainWindowRuntimeGateTests {
    private final class RefreshCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private final class InstallFixture: InstallRepository, @unchecked Sendable {
        var setupState: RuntimeSetupState
        let setupSubject = PassthroughSubject<RuntimeSetupState, Never>()
        let installCounter = RefreshCounter()

        init(_ state: RuntimeSetupState) { self.setupState = state }
        func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> { setupSubject.eraseToAnyPublisher() }
        var state: InstallState { .installed }
        func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.installed).eraseToAnyPublisher() }
        var lastCheckMessage: String? { nil }
        func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        func install() async { installCounter.increment() }
        func retry() async {}
        func reset() {}
    }

    @Test func givenPendingStop_whenRuntimeQualificationIsLost_thenRequestIsDiscarded() async {
        // given
        let install = InstallFixture(.ready)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install)
        sut.selection = .task("task")
        var confirmations = 0
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: []) { confirmations += 1 }
        sut.presentStopConfirmation(request)
        #expect(sut.presentedSheet == .stopTask)
        // when
        install.setupSubject.send(.checking)
        await waitUntil { !sut.runtimeIsReady }
        sut.confirmStop(requestID: request.id)
        // then
        #expect(sut.presentedSheet == nil)
        #expect(sut.stopConfirmation == nil)
        #expect(confirmations == 0)
    }

    private func pendingStopRequest(cancels: @escaping @MainActor (PendingLaunchStopCancelReason) -> Void,
                                    confirms: @escaping @MainActor () -> Void) -> PendingLaunchStopRequest {
        PendingLaunchStopRequest(id: UUID(), taskID: "20261110-093000-a17c92", confirm: confirms, cancel: cancels, didDismiss: { _ in })
    }

    @Test func givenRuntimeIsNotReady_whenPendingStopIsPresented_thenRejectedWithDiscardOnce() {
        // given
        let install = InstallFixture(.installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install)
        sut.selection = .pendingLaunches
        var cancels: [PendingLaunchStopCancelReason] = []
        var confirms = 0
        // when
        sut.presentPendingLaunchStop(pendingStopRequest(cancels: { cancels.append($0) }, confirms: { confirms += 1 }))
        // then
        #expect(cancels == [.discard])
        #expect(confirms == 0)
        #expect(sut.presentedSheet == nil)
        #expect(sut.pendingStopRequest == nil)
    }

    @Test func givenPendingStopSheet_whenRuntimeQualificationIsLost_thenDiscardedOnceAndALateConfirmIsInert() async {
        // given
        let install = InstallFixture(.ready)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install)
        sut.selection = .pendingLaunches
        var cancels: [PendingLaunchStopCancelReason] = []
        var confirms = 0
        let request = pendingStopRequest(cancels: { cancels.append($0) }, confirms: { confirms += 1 })
        sut.presentPendingLaunchStop(request)
        #expect(sut.presentedSheet == .stopPendingLaunch)
        // when
        install.setupSubject.send(.checking)
        await waitUntil { !sut.runtimeIsReady }
        #expect(!sut.runtimeIsReady)
        sut.confirmPendingStop(requestID: request.id)
        sut.cancelPendingStop(requestID: request.id)
        sut.dismissPendingLaunchStop()
        // then: readiness and the sheet are cleared together, so a confirmation cannot reach the view model.
        #expect(cancels == [.discard])
        #expect(confirms == 0)
        #expect(sut.presentedSheet == nil)
        #expect(sut.pendingStopRequest == nil)
    }

    @Test func givenRuntimeIsNotReady_whenPresentingOrRoutingCreation_thenCreationIsBlocked() {
        let install = InstallFixture(.installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent, installRepository: install)

        sut.presentedSheet = .newSession
        sut.handle(path: MonitorDestination.newSession)
        sut.handle(path: MonitorDestination.newWorkflow(UUID()))
        sut.handle(path: MonitorDestination.workflow("draft"))

        #expect(!sut.runtimeIsReady)
        #expect(sut.presentedSheet == nil)
        #expect(sut.selection == nil)
    }

    @Test func givenRuntimeBecomesReady_whenCreationIsRequested_thenCreationIsRestored() async {
        let install = InstallFixture(.installationRequired(installedVersion: "0.0.1", requiredVersion: "0.0.2"))
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install)
        install.setupState = .ready
        install.setupSubject.send(.ready)
        await waitUntil { sut.runtimeIsReady }

        sut.handle(path: MonitorDestination.newSession)

        #expect(sut.runtimeIsReady)
        #expect(sut.presentedSheet == nil)
        #expect(sut.selection == .newSession)
    }

    @Test func givenQualifiedRuntimeBeforeFirstListing_whenReadFailsAndRetries_thenSetupIsNotRequested() async {
        // given
        let install = InstallFixture(.ready)
        let listing = MockTaskListRepository()
        let listed = CurrentValueSubject<Bool, Never>(false)
        let errors = CurrentValueSubject<ToolError?, Never>(nil)
        given(listing).hasListed.willReturn(false)
        given(listing).listError.willReturn(nil)
        given(listing).tasksPublisher().willReturn(Empty<[TaskInfo], Never>().eraseToAnyPublisher())
        given(listing).tasks.willReturn([])
        given(listing).hasListedPublisher().willReturn(listed.eraseToAnyPublisher())
        given(listing).titlesPublisher().willReturn(Just<[String: String]>([:]).eraseToAnyPublisher())
        given(listing).listErrorPublisher().willReturn(errors.eraseToAnyPublisher())
        let refreshes = RefreshCounter()
        given(listing).refreshAndWait().willProduce { refreshes.increment(); return .success(()) }
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install, taskListRepository: listing)
        // when
        errors.send(.timedOut(tool: "harflow-ctl task-list-page", seconds: 30))
        await waitUntil { sut.loadingWorkError != nil }
        // then
        #expect(sut.runtimeIsReady)
        #expect(sut.runtimeSetupState == .ready)
        #expect(!sut.hasLoadedWork)
        #expect(install.installCounter.value == 0)
        sut.retryLoadingWork()
        await waitUntil { refreshes.value == 1 }
        // when
        listed.send(true)
        errors.send(nil)
        await waitUntil { sut.hasLoadedWork && sut.loadingWorkError == nil }
        sut.selection = .task("retained")
        errors.send(.timedOut(tool: "harflow-ctl task-list-page", seconds: 30))
        await waitUntil { sut.loadingWorkError != nil }
        // then
        #expect(sut.hasLoadedWork)
        #expect(sut.selection == .task("retained"))
        #expect(install.installCounter.value == 0)
        #expect(sut.runtimeIsReady)
    }

    // MARK: - Contract and capability gates

    private struct ListingFixture {
        let listing = MockTaskListRepository()
        let listed: CurrentValueSubject<Bool, Never>
        let errors = CurrentValueSubject<ToolError?, Never>(nil)
        let refreshes = RefreshCounter()

        init(hasListed: Bool = false) {
            self.listed = CurrentValueSubject(hasListed)
            given(listing).hasListed.willReturn(hasListed)
            given(listing).listError.willReturn(nil)
            given(listing).tasksPublisher().willReturn(Empty<[TaskInfo], Never>().eraseToAnyPublisher())
            given(listing).tasks.willReturn([])
            given(listing).hasListedPublisher().willReturn(listed.eraseToAnyPublisher())
            given(listing).titlesPublisher().willReturn(Just<[String: String]>([:]).eraseToAnyPublisher())
            given(listing).listErrorPublisher().willReturn(errors.eraseToAnyPublisher())
            let counter = refreshes
            given(listing).refreshAndWait().willProduce { counter.increment(); return .success(()) }
        }
    }

    private static let contractError = ToolError.unsupportedVersion(tool: "harflow-ctl", version: "2")
    private static let capabilityError = WireEnvelope.incompatibility(WireEnvelope.Detail.missingContract("events.v1"))

    @Test(arguments: [false, true])
    func givenReadyRuntime_whenTheListingIsRefusedByContract_thenTheGateShowsBeforeAndAfterTheFirstListing(hasListed: Bool) async {
        // given
        let fixture = ListingFixture(hasListed: hasListed)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        #expect(sut.mainGate == nil)
        #expect(sut.workIsAvailable)
        // when
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        // then
        #expect(sut.mainGate == .contractRefused(status: Self.contractError.message, code: nil))
        #expect(!sut.workIsAvailable)
        #expect(sut.runtimeIsReady)
    }

    @Test func givenACapabilityGate_whenTheRefusalIsAnIncompatibility_thenTheGateKeepsTheCode() async {
        // given
        let fixture = ListingFixture()
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        // when
        fixture.errors.send(Self.capabilityError)
        await waitUntil { sut.mainGate != nil }
        // then
        #expect(sut.mainGate == .capabilityMissing(status: Self.capabilityError.displayMessage, code: "incompatible_runtime"))
        #expect(sut.loadingWorkError == LoadingWorkError(message: Self.capabilityError.displayMessage, code: "incompatible_runtime"))
    }

    @Test func givenAContractGate_whenCreationIsRequestedByEveryPath_thenNothingIsCreated() async {
        // given
        let fixture = ListingFixture(hasListed: true)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        // when
        sut.openNewSession()
        sut.handle(path: MonitorDestination.newSession)
        sut.handle(path: MonitorDestination.newWorkflow(UUID()))
        sut.handle(path: MonitorDestination.workflow("draft"))
        sut.handle(path: MonitorDestination.workflowLibrary)
        sut.select(.newSession)
        sut.select(.newWorkflow(UUID()))
        sut.presentWorkflowRunner()
        sut.presentedSheet = .workflowRunner
        sut.isNewSessionPresented = true
        // then
        #expect(sut.selection == nil)
        #expect(sut.presentedSheet == nil)
        #expect(!sut.isNewSessionPresented)
    }

    @Test func givenAContractGate_whenTheListingRecovers_thenTheGateClearsAndCreationIsRestored() async {
        // given
        let fixture = ListingFixture(hasListed: true)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        // when
        fixture.errors.send(nil)
        await waitUntil { sut.mainGate == nil }
        sut.openNewSession()
        // then
        #expect(sut.workIsAvailable)
        #expect(sut.selection == .newSession)
    }

    @Test func givenAContractGate_whenRetryIsTapped_thenTheListingIsRefreshedOnce() async {
        // given
        let fixture = ListingFixture()
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        // when
        sut.retryLoadingWork()
        await waitUntil { fixture.refreshes.value == 1 }
        // then
        #expect(fixture.refreshes.value == 1)
    }

    @Test func givenAnotherListingFailure_whenObserved_thenNoGateShowsAndWorkStaysAvailable() async {
        // given
        let fixture = ListingFixture()
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        // when
        fixture.errors.send(.timedOut(tool: "harflow-ctl task-list-page", seconds: 30))
        await waitUntil { sut.loadingWorkError != nil }
        // then
        #expect(sut.mainGate == nil)
        #expect(sut.workIsAvailable)
    }

    @Test func givenARuntimeThatIsNotReady_whenTheListingIsRefused_thenTheSetupGateStaysTheOnlyGate() async {
        // given
        let fixture = ListingFixture()
        let install = InstallFixture(.installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install, taskListRepository: fixture.listing)
        // when
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.loadingWorkError != nil }
        // then
        #expect(sut.mainGate == nil)
        // when the runtime becomes ready while the refusal stands
        install.setupState = .ready
        install.setupSubject.send(.ready)
        await waitUntil { sut.mainGate != nil }
        // then
        #expect(sut.mainGate == .contractRefused(status: Self.contractError.message, code: nil))
    }

    @Test func givenAContractGate_whenARefusalIsRepeated_thenTheGateIsNotWrittenAgain() async {
        // given
        let fixture = ListingFixture()
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        let changes = RefreshCounter()
        func track() {
            withObservationTracking { _ = sut.mainGate } onChange: { changes.increment() }
        }
        track()
        // when — the same refusal again, then a different error that still classifies the same way
        fixture.errors.send(Self.contractError)
        fixture.errors.send(Self.contractError)
        fixture.errors.send(.unsupportedVersion(tool: "harflow-ctl", version: "2"))
        try? await Task.sleep(for: .milliseconds(150))
        // then
        #expect(changes.value == 0)
    }

    @Test func givenAnOpenWorkflowRunner_whenAGateArrives_thenTheRunnerCloses() async {
        // given
        let fixture = ListingFixture(hasListed: true)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        sut.presentWorkflowRunner()
        #expect(sut.presentedSheet == .workflowRunner)
        // when
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        // then
        #expect(sut.presentedSheet == nil)
    }

    @Test func givenAContractGate_whenTaskAndStatisticsAreRouted_thenTheyStillRoute() async {
        // given
        let fixture = ListingFixture(hasListed: true)
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: InstallFixture(.ready),
                                        taskListRepository: fixture.listing)
        fixture.errors.send(Self.contractError)
        await waitUntil { sut.mainGate != nil }
        // when / then
        sut.handle(path: MonitorDestination.task("abc"))
        #expect(sut.selection == .task("abc"))
        sut.handle(path: MonitorDestination.statistics)
        #expect(sut.selection == .statistics)
        sut.select(.task("def"))
        #expect(sut.selection == .task("def"))
    }

    // MARK: - Store gate

    private final class StoreFixture: StateRecoveryRepository, @unchecked Sendable {
        let subject: CurrentValueSubject<StoreRecoveryState, Never>

        init(_ state: StoreRecoveryState = .idle) { self.subject = CurrentValueSubject(state) }
        var state: StoreRecoveryState { subject.value }
        func statePublisher() -> AnyPublisher<StoreRecoveryState, Never> { subject.eraseToAnyPublisher() }
        func report(_: ToolError) {}
        func inspect() async {}
        func requestConfirmation(inspection _: StateInspection) {}
        func cancelConfirmation() {}
        func recover(inspection _: StateInspection) async {}
        func invalidate() {}
    }

    private static let storeRefusal = ToolError.structuredRefusal(
        code: "state_incompatible",
        message: "Unsupported state root: foreign store marker; inspect state or select a fresh state root",
        data: ["reason": .string("foreign_store"), "state_root": .string("/tmp/harflow-state")]
    )

    private func makeStoreSUT(store: StoreFixture, install: InstallFixture = InstallFixture(.ready),
                              fixture: ListingFixture = ListingFixture(hasListed: true)) -> MainWindowCoordinator {
        MainWindowCoordinator(parent: MockCoordinator(), installRepository: install, taskListRepository: fixture.listing,
                              stateRecoveryRepository: store)
    }

    @Test func givenReadyRuntime_whenTheStoreRefusesWork_thenTheStoreGateShowsAndWorkIsUnavailable() async {
        // given
        let store = StoreFixture()
        let sut = makeStoreSUT(store: store)
        #expect(sut.mainGate == nil)
        // when
        store.subject.send(.incompatible(Self.storeRefusal))
        await waitUntil { sut.mainGate != nil }
        // then
        #expect(sut.mainGate == .storeUnusable(StoreAttention(error: Self.storeRefusal)))
        #expect(!sut.workIsAvailable)
        #expect(sut.runtimeIsReady)
    }

    @Test func givenAnUnusableStoreAtLaunch_whenTheCoordinatorIsBuilt_thenTheGateShowsAtOnce() {
        // given / when
        let sut = makeStoreSUT(store: StoreFixture(.incompatible(Self.storeRefusal)))
        // then
        #expect(sut.mainGate == .storeUnusable(StoreAttention(error: Self.storeRefusal)))
        #expect(!sut.workIsAvailable)
    }

    @Test func givenTheStoreGate_whenCreationIsRequestedByEveryPath_thenNothingIsCreated() async {
        // given
        let store = StoreFixture(.incompatible(Self.storeRefusal))
        let sut = makeStoreSUT(store: store)
        // when
        sut.openNewSession()
        sut.handle(path: MonitorDestination.newSession)
        sut.handle(path: MonitorDestination.newWorkflow(UUID()))
        sut.handle(path: MonitorDestination.workflowLibrary)
        sut.select(.newSession)
        sut.presentWorkflowRunner()
        sut.isNewSessionPresented = true
        // then
        #expect(sut.selection == nil)
        #expect(sut.presentedSheet == nil)
        #expect(!sut.isNewSessionPresented)
    }

    @Test func givenTheStoreGate_whenTheStoreIsRecoveredOrInspectedAsReady_thenTheGateClearsAndCreationIsRestored() async {
        // given
        let store = StoreFixture(.incompatible(Self.storeRefusal))
        let sut = makeStoreSUT(store: store)
        #expect(sut.mainGate != nil)
        // when
        store.subject.send(.idle)
        await waitUntil { sut.mainGate == nil }
        sut.openNewSession()
        // then
        #expect(sut.workIsAvailable)
        #expect(sut.selection == .newSession)
    }

    @Test(arguments: [false, true])
    func givenTheStoreGate_whenAnInspectionOrRecoveryIsInFlight_thenOnlyTheOutcomeDecidesTheGate(hasListed: Bool) async {
        // given
        let store = StoreFixture(.incompatible(Self.storeRefusal))
        let sut = makeStoreSUT(store: store, fixture: ListingFixture(hasListed: hasListed))
        // when the inspection runs, the gate clears (the store state is no longer a refusal)
        store.subject.send(.inspecting)
        await waitUntil { sut.mainGate == nil }
        // then it returns with the inspection's own verdict
        let inspection = StateInspection([
            "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"), "status": .string("interrupted"),
            "reason": .string("recovery_interrupted"), "message": .string("Explicit recovery must be resumed"),
            "recovery_supported": .bool(false), "cooperative_ownership_only": .bool(true)
        ])!
        store.subject.send(.inspected(inspection))
        await waitUntil { sut.mainGate != nil }
        #expect(sut.mainGate == .storeUnusable(StoreAttention.from(inspection: inspection)!))
    }

    @Test func givenTheStoreGate_whenTheRuntimeIsNotReady_thenTheSetupGateIsTheOnlyGate() async {
        // given
        let install = InstallFixture(.installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let sut = makeStoreSUT(store: StoreFixture(.incompatible(Self.storeRefusal)), install: install)
        // then
        #expect(sut.mainGate == nil)
        // when the runtime becomes ready while the store still refuses
        install.setupState = .ready
        install.setupSubject.send(.ready)
        await waitUntil { sut.mainGate != nil }
        // then
        #expect(sut.mainGate == .storeUnusable(StoreAttention(error: Self.storeRefusal)))
    }

    @Test func givenTheStoreGate_whenARepeatedStateArrives_thenTheGateIsNotWrittenAgain() async {
        // given
        let store = StoreFixture(.incompatible(Self.storeRefusal))
        let sut = makeStoreSUT(store: store)
        let changes = RefreshCounter()
        withObservationTracking { _ = sut.mainGate } onChange: { changes.increment() }
        // when
        store.subject.send(.incompatible(Self.storeRefusal))
        store.subject.send(.incompatible(Self.storeRefusal))
        try? await Task.sleep(for: .milliseconds(150))
        // then
        #expect(changes.value == 0)
    }

    @Test func givenTheStoreGate_whenAContractErrorArrives_thenTheStoreGateStaysUntilTheStoreClears() async {
        // given
        let store = StoreFixture(.incompatible(Self.storeRefusal))
        let fixture = ListingFixture(hasListed: true)
        let sut = makeStoreSUT(store: store, fixture: fixture)
        // when
        fixture.errors.send(Self.contractError)
        try? await Task.sleep(for: .milliseconds(100))
        // then
        #expect(sut.mainGate == .storeUnusable(StoreAttention(error: Self.storeRefusal)))
        // when
        store.subject.send(.idle)
        await waitUntil { sut.mainGate == .contractRefused(status: Self.contractError.message, code: nil) }
        // then
        #expect(sut.mainGate == .contractRefused(status: Self.contractError.message, code: nil))
    }
}
