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
    @Test func givenRuntimeBecomesReady_whenObserved_thenStatusAndQualificationsLoadOnce() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let populated = document(twoRowsJSON)
        given(useCase).status().willProduce {
            calls.value += 1
            return .success(populated)
        }
        let setup = CurrentValueSubject<RuntimeSetupState, Never>(.checking)
        Self.stubRuntime(useCase, runtimeSetupState: .checking, runtimeSetupPublisher: setup.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await Task.yield()
        #expect(calls.value == 0)
        #expect(sut.showsRuntimeSetup)

        // when
        setup.send(.ready)

        // then
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.showsRuntimeSetup == false)
        #expect(calls.value == 1)
        verify(useCase).qualificationBackends().called(1)

        // Repeated readiness is quiet; the queue marker drains scheduled delivery first.
        setup.send(.ready)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await Task.yield()
        #expect(calls.value == 1)
    }

    @Test func givenARuntimeReadyAtStart_whenTheReplayedSnapshotArrives_thenItLoadsOnlyOnce() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let populated = document(twoRowsJSON)
        given(useCase).status().willProduce {
            calls.value += 1
            return .success(populated)
        }
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)

        // when
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await Task.yield()

        // then
        #expect(calls.value == 1)
        verify(useCase).qualificationBackends().called(1)
    }

    @Test func givenRuntimeBecomesReadyFromOffMainContext_whenObserved_thenHarnessesLoads() async {
        // given — regression guard: the managed-runtime state is sent from an actor, not the main thread
        final class CallCount { var value = 0 }
        final class SendableSubject: @unchecked Sendable {
            let subject = CurrentValueSubject<RuntimeSetupState, Never>(.checking)
        }
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        let calls = CallCount()
        let populated = document(twoRowsJSON)
        given(useCase).status().willProduce {
            calls.value += 1
            return .success(populated)
        }
        let setup = SendableSubject()
        Self.stubRuntime(useCase, runtimeSetupState: .checking, runtimeSetupPublisher: setup.subject.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        #expect(calls.value == 0)

        // when
        await Task.detached { setup.subject.send(.ready) }.value

        // then
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(calls.value == 1)
    }

    @Test func givenARemount_whenTheRuntimeIsReadyAgain_thenItLoadsOncePerAppearance() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        final class CallCount { var value = 0 }
        let calls = CallCount()
        let populated = document(twoRowsJSON)
        given(useCase).status().willProduce {
            calls.value += 1
            return .success(populated)
        }
        let setup = CurrentValueSubject<RuntimeSetupState, Never>(.ready)
        Self.stubRuntime(useCase, runtimeSetupPublisher: setup.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { calls.value == 1 && !sut.isLoading }
        #expect(calls.value == 1)

        // when — a leave and return with an unchanged ready runtime
        sut.didDisappear()
        sut.didAppear()

        // then
        await waitUntil { calls.value == 2 && !sut.isLoading }
        #expect(calls.value == 2)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await Task.yield()
        #expect(calls.value == 2)
    }

    @Test func givenARowFailureAndRows_whenRuntimeStopsBeingReady_thenThePageClears() async {
        // given
        let setup = CurrentValueSubject<RuntimeSetupState, Never>(.ready)
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase).perform(.any, client: .any, using: .any).willReturn(.failure(.launchFailed(tool: "harflow-setup", detail: "crashed")))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase, runtimeSetupPublisher: setup.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "claude-code" }!
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        await waitUntil { !sut.rowFailures.isEmpty }
        #expect(sut.rowFailures.count == 1)

        // when
        setup.send(.failed("Runtime preparation failed."))

        // then
        await waitUntil { sut.showsRuntimeSetup }
        #expect(sut.showsRuntimeSetup)
        #expect(sut.rows.isEmpty)
        #expect(sut.rowFailures.isEmpty)
        #expect(sut.workingKey == nil)
        #expect(sut.serverPath == nil)
        #expect(sut.qualificationCards.isEmpty)
        #expect(sut.isRefreshDisabled)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenAStatusLoadInFlight_whenRuntimeStopsBeingReady_thenTheLateAnswerIsDropped() async {
        // given — `status()` loses readiness from inside the call, so the answer resolves into a not-ready page.
        // (Mockable's `willProduce` is synchronous, so a held-open call cannot be raced directly.)
        final class SUTBox { var sut: HarnessesVM? }
        let sutBox = SUTBox()
        let populated = document(twoRowsJSON)
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willProduce {
            sutBox.sut?.setRuntimeReady(false)
            return .success(populated)
        }
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sutBox.sut = sut

        // when
        sut.didAppear()

        // then
        await verify(useCase).status().calledEventually(1, before: .seconds(5))
        await waitUntil { sut.showsRuntimeSetup }
        #expect(sut.showsRuntimeSetup)
        #expect(sut.rows.isEmpty)
        #expect(sut.serverPath == nil)
        #expect(!sut.isLoading)
    }

    @Test func givenAnActionInFlight_whenReadinessIsLostAndRegained_thenTheStaleFailureIsDropped() async {
        // given — `perform()` loses and regains readiness from inside the call, then fails.
        final class SUTBox { var sut: HarnessesVM? }
        let sutBox = SUTBox()
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase).perform(.any, client: .any, using: .any).willProduce { _, _, _ in
            sutBox.sut?.setRuntimeReady(false)
            sutBox.sut?.setRuntimeReady(true)
            return .failure(.launchFailed(tool: "harflow-setup", detail: "crashed"))
        }
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sutBox.sut = sut
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "claude-code" }!

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        await verify(useCase).perform(.any, client: .any, using: .any).calledEventually(1, before: .seconds(5))
        await waitUntil { sut.workingKey == nil }
        sut.didTapRefresh()

        // then — the fresh page carries no failure from the stale action
        await waitUntil { sut.rows.count == 2 && !sut.isLoading }
        #expect(sut.rows.count == 2)
        #expect(sut.rowFailures.isEmpty)
        #expect(sut.workingKey == nil)
        withExtendedLifetime(cancellable) {}
    }
}
