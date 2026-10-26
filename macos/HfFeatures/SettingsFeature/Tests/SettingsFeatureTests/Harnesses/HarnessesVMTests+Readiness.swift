import Combine
import Foundation
import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

// MARK: - HarnessesVMTests readiness recovery

extension HarnessesVMTests {
    @Test func givenPreparationFailure_whenRuntimeBecomesReadyWithoutInstallNotice_thenHarnessesReloads() async {
        // given
        let useCase = MockHarnessesUseCase()
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let populated = document(twoRowsJSON)
        given(useCase).status().willProduce {
            calls.value += 1
            return calls.value == 1
                ? .failure(.refused(code: "managed_runtime_preparing", message: "Preparing runtime"))
                : .success(populated)
        }
        let setup = CurrentValueSubject<RuntimeSetupState, Never>(.checking)
        Self.stubInstall(useCase, runtimeSetupPublisher: setup.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { calls.value == 1 && !sut.isLoading }
        #expect(calls.value == 1)
        #expect(sut.rows.isEmpty)

        // when
        setup.send(.ready)

        // then
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.errorMessage == nil)
        #expect(sut.installBannerModel == nil)
        #expect(calls.value == 2)

        // Repeated readiness is quiet; the queue marker drains scheduled delivery first.
        setup.send(.ready)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await Task.yield()
        #expect(calls.value == 2)
    }

    @Test func givenExplicitInstall_whenReadyAndInstalledArrive_thenHarnessesRefreshesOnceAndDismissalIsQuiet() async {
        // given
        let useCase = MockHarnessesUseCase()
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let populated = document(twoRowsJSON)
        given(useCase).status().willProduce {
            calls.value += 1
            return .success(populated)
        }
        let setup = CurrentValueSubject<RuntimeSetupState, Never>(.ready)
        let notice = CurrentValueSubject<InstallState, Never>(.idle)
        Self.stubInstall(useCase, installStatePublisher: notice.eraseToAnyPublisher(), runtimeSetupPublisher: setup.eraseToAnyPublisher(),
                         onReset: { notice.send(.idle) })
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { calls.value == 1 && !sut.isLoading }
        #expect(calls.value == 1)

        // when
        setup.send(.installing)
        setup.send(.ready)
        notice.send(.installed)

        // then
        await waitUntil { calls.value == 2 && sut.installBannerModel?.title == "harflow is installed" }
        #expect(calls.value == 2)
        #expect(sut.installBannerModel?.title == "harflow is installed")
        sut.didTapInstallBannerDismiss()
        await waitUntil { sut.installBannerModel == nil }
        #expect(sut.installBannerModel == nil)
        #expect(calls.value == 2)

        // Remount loads once from the current ready snapshot, without another transition load.
        sut.didDisappear()
        sut.didAppear()
        await waitUntil { calls.value == 3 && !sut.isLoading }
        #expect(calls.value == 3)
        #expect(sut.installBannerModel == nil)
        setup.send(.checking)
        setup.send(.ready)
        await waitUntil { calls.value == 4 && !sut.isLoading }
        #expect(calls.value == 4)
    }
}
