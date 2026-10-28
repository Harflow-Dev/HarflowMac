import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
struct SettingsQualificationTests {
    private func make(_ fixture: QualificationFixture, session: QualificationSession? = nil) -> HarnessesVM {
        let useCase = MockHarnessesUseCase()
        HarnessesVMTests.stubInstall(useCase)
        given(useCase).status().willReturn(.failure(.launchFailed(tool: "fixture", detail: "Fixture registration status unavailable")))
        given(useCase).qualificationBackends().willReturn(["fixture"])
        given(useCase).qualificationSession().willReturn(session ?? QualificationSession(repository: fixture))
        return HarnessesVM(useCase: useCase)
    }

    @Test func givenCachedFeatureEvidence_whenSettingsOpens_thenInspectWithoutProviderCheck() async {
        // given
        let fixture = QualificationFixture()
        let vm = make(fixture)
        // when
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .ready }
        // then
        #expect(fixture.checks == 0)
        #expect(vm.qualificationCards.first?.model.features.map(\.id) == ["write"])
        vm.didDisappear()
    }

    @Test func givenFailedFeature_whenExplicitlyRetried_thenOnlyQualificationCheckRuns() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let vm = make(fixture)
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        // when
        fixture.setReady(true)
        vm.didTapQualification("fixture:settings/fixture")
        await waitUntil { vm.qualificationCards.first?.model.state == .ready }
        // then
        #expect(fixture.checks == 1)
        vm.didDisappear()
    }

    @Test func givenUnsupportedEngine_whenSettingsOpens_thenUnsupportedIsDistinctFromRegistrationStatus() async {
        // given
        let fixture = QualificationFixture(error: .unsupportedCommand(tool: "harflow-ctl", command: "qualification", detail: "fixture"))
        let vm = make(fixture)
        // when
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .unsupported }
        // then
        #expect(fixture.checks == 0)
        vm.didDisappear()
    }

    @Test func givenTwoBackendReadFailures_whenRetryingSecondCard_thenOnlyItsOwnHarnessIsChecked() async {
        // given
        let first = CachedFailureQualificationFixture()
        let second = CachedFailureQualificationFixture()
        let queue = QualificationSessionQueue([QualificationSession(repository: first), QualificationSession(repository: second)])
        let useCase = MockHarnessesUseCase()
        HarnessesVMTests.stubInstall(useCase)
        given(useCase).status().willReturn(.failure(.launchFailed(tool: "fixture", detail: "Fixture registration status")))
        given(useCase).qualificationBackends().willReturn(["first", "second"])
        given(useCase).qualificationSession().willProduce { queue.next() }
        let vm = HarnessesVM(useCase: useCase)
        vm.didAppear()
        await waitUntil { vm.qualificationCards.count == 2 && vm.qualificationCards.allSatisfy { $0.model.state == .failed } }
        // when
        vm.didTapQualification("second:qualification")
        await waitUntil { vm.qualificationCards.contains { $0.owner == "second" && $0.model.state == .ready } }
        // then
        #expect(Set(vm.qualificationCards.map(\.id)).count == 2)
        #expect(first.checks == 0)
        #expect(second.checks == 1)
        #expect(vm.qualificationCards.first(where: { $0.owner == "first" })?.model.state == .failed)
        #expect(vm.qualificationCards.first(where: { $0.owner == "first" })?.model.identity == "First")
        vm.didDisappear()
    }

    @Test func givenCheckingSettingsHarness_whenCancelTapped_thenCancelledWithoutClaimingEngineStopped() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let gate = QualificationCheckGate()
        let session = QualificationSession(repository: SuspendedQualificationFixture(base: fixture, gate: gate))
        let vm = make(fixture, session: session)
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        vm.didTapQualification("fixture:settings/fixture")
        await gate.waitForEntry()
        await waitUntil { vm.qualificationCards.first?.model.state == .checking }
        // when
        vm.didTapQualification("fixture:settings/fixture")
        await waitUntil { vm.qualificationCards.first?.model.state == .cancelled }
        await gate.open()
        // then
        #expect(await session.snapshot.phase == .cancelled)
        #expect(vm.qualificationCards.first?.model.message.contains("Late results") == true)
        vm.didDisappear()
    }

}
