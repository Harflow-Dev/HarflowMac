import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct MainWindowHeldTaskLinkTests {
    private final class InstallFixture: InstallRepository, @unchecked Sendable {
        var setupState: RuntimeSetupState
        let setupSubject = PassthroughSubject<RuntimeSetupState, Never>()

        init(_ state: RuntimeSetupState) { self.setupState = state }
        func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> { setupSubject.eraseToAnyPublisher() }
        var state: InstallState { .installed }
        func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.installed).eraseToAnyPublisher() }
        func install() async {}

        func send(_ state: RuntimeSetupState) {
            setupState = state
            setupSubject.send(state)
        }
    }

    private static let installRequired = RuntimeSetupState.installationRequired(installedVersion: nil, requiredVersion: "0.0.14")

    private func makeSUT(_ state: RuntimeSetupState = installRequired) -> (sut: MainWindowCoordinator, install: InstallFixture) {
        let install = InstallFixture(state)
        return (MainWindowCoordinator(parent: MockCoordinator(), installRepository: install), install)
    }

    // MARK: - Holding

    @Test func givenInstallRequired_whenATaskLinkArrives_thenItIsSelectedAndHeld() {
        // given
        let (sut, _) = makeSUT()
        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        // then
        #expect(sut.selection == .task("abc123"))
        #expect(sut.heldTaskLink == "abc123")
    }

    @Test func givenAHeldLink_whenASecondLinkArrives_thenTheLatestReplacesIt() {
        // given
        let (sut, _) = makeSUT()
        sut.handle(path: MonitorDestination.task("first"))
        // when
        sut.handle(path: MonitorDestination.task("second"))
        // then
        #expect(sut.selection == .task("second"))
        #expect(sut.heldTaskLink == "second")
    }

    @Test func givenAHeldLink_whenTheSameLinkArrivesAgain_thenItStaysHeld() {
        // given
        let (sut, _) = makeSUT()
        sut.handle(path: MonitorDestination.task("abc123"))
        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        // then
        #expect(sut.heldTaskLink == "abc123")
    }

    @Test func givenAReadyRuntime_whenATaskLinkArrives_thenNothingIsHeld() {
        // given
        let (sut, _) = makeSUT(.ready)
        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        // then
        #expect(sut.selection == .task("abc123"))
        #expect(sut.heldTaskLink == nil)
    }

    // MARK: - Release

    @Test func givenAHeldLink_whenTheRuntimeBecomesReady_thenTheHoldClearsAndTheSelectionStays() async {
        // given
        let (sut, install) = makeSUT()
        sut.handle(path: MonitorDestination.task("abc123"))
        // when
        install.send(.ready)
        await waitUntil { sut.runtimeIsReady }
        // then
        #expect(sut.heldTaskLink == nil)
        #expect(sut.selection == .task("abc123"))
    }

    @Test func givenAHeldLink_whenSetupFails_thenTheLinkIsKeptForTheRetry() async {
        // given
        let (sut, install) = makeSUT()
        sut.handle(path: MonitorDestination.task("abc123"))
        // when
        install.send(.installing)
        install.send(.failed("The managed runtime could not be prepared."))
        await waitUntil { sut.runtimeSetupState == .failed("The managed runtime could not be prepared.") }
        // then
        #expect(sut.heldTaskLink == "abc123")
        #expect(sut.selection == .task("abc123"))
        // when the retry succeeds
        install.send(.ready)
        await waitUntil { sut.runtimeIsReady }
        // then
        #expect(sut.heldTaskLink == nil)
        #expect(sut.selection == .task("abc123"))
    }

    @Test func givenAHeldLink_whenTheSelectionMovesElsewhere_thenTheHoldClears() {
        // given
        let (sut, _) = makeSUT()
        sut.handle(path: MonitorDestination.task("abc123"))
        // when
        sut.selection = .statistics
        // then
        #expect(sut.heldTaskLink == nil)
    }

    @Test func givenAHeldLink_whenTheSelectionIsClearedAndTheLinkArrivesAgain_thenItIsHeldAgain() {
        // given
        let (sut, _) = makeSUT()
        sut.handle(path: MonitorDestination.task("abc123"))
        sut.selection = nil
        #expect(sut.heldTaskLink == nil)
        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        // then
        #expect(sut.heldTaskLink == "abc123")
    }

    @Test func givenAHeldLink_whenAnUpdateFailsAndIsRetried_thenTheHoldSurvivesUntilReady() async {
        // given
        let (sut, install) = makeSUT(.installationRequired(installedVersion: "0.0.13", requiredVersion: "0.0.14"))
        sut.handle(path: MonitorDestination.task("abc123"))
        // when
        install.send(.updating(installedVersion: "0.0.13", requiredVersion: "0.0.14"))
        install.send(.updateFailed(message: "Package verification failed.", installedVersion: "0.0.13", requiredVersion: "0.0.14"))
        await waitUntil { sut.runtimeSetupState != .installationRequired(installedVersion: "0.0.13", requiredVersion: "0.0.14") }
        await waitUntil {
            if case .updateFailed = sut.runtimeSetupState { return true }
            return false
        }
        // then
        #expect(sut.heldTaskLink == "abc123")
        // when
        install.send(.ready)
        await waitUntil { sut.runtimeIsReady }
        // then
        #expect(sut.heldTaskLink == nil)
        #expect(sut.selection == .task("abc123"))
    }

    // MARK: - Copy

    @Test(arguments: [
        (RuntimeSetupState.checking, true, RuntimeSetupWelcomeView.heldTaskLinkStatus),
        (RuntimeSetupState.checking, false, nil),
        (RuntimeSetupState.installationRequired(installedVersion: nil, requiredVersion: "0.0.14"), true,
         "After setup, Harflow opens the task you linked to."),
        (RuntimeSetupState.installationRequired(installedVersion: nil, requiredVersion: "0.0.14"), false, nil),
        (RuntimeSetupState.installationRequired(installedVersion: "0.0.13", requiredVersion: "0.0.14"), true,
         "After setup, Harflow opens the task you linked to."),
        (RuntimeSetupState.installing, true, "Installation in progress"),
        (RuntimeSetupState.updating(installedVersion: "0.0.13", requiredVersion: "0.0.14"), true, "Update in progress"),
        (RuntimeSetupState.failed("Package verification failed."), true, "Package verification failed."),
        (RuntimeSetupState.updateFailed(message: "Package verification failed.", installedVersion: "0.0.13", requiredVersion: "0.0.14"),
         true, "Package verification failed."),
        (RuntimeSetupState.ready, true, nil)
    ])
    func givenAGateState_whenTheStatusIsBuilt_thenTheHeldLinkLineShowsOnlyWhereTheStatusIsEmpty(
        state: RuntimeSetupState, holdsLink: Bool, expected: String?
    ) {
        // when
        let status = RuntimeSetupWelcomeView.statusText(for: state, holdsTaskLink: holdsLink)
        // then
        #expect(status == expected)
    }
}
