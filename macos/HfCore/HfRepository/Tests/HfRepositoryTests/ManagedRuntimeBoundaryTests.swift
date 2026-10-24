import Foundation
@testable import HfRepository
import MonitorCore
import SwiftEnvironment
import Testing

@Suite("Managed runtime boundary", .serialized)
@MainActor
struct ManagedRuntimeBoundaryTests {
    private struct FailingInstaller: ManagedRuntimeInstalling {
        func prepare() async throws -> ManagedRuntimeReady {
            throw ManagedRuntimeFailure("fixture runtime failure")
        }

        func checkExisting() async throws -> ManagedRuntimeAvailability {
            throw ManagedRuntimeFailure("fixture runtime failure")
        }
    }

    private struct ReadyInstaller: ManagedRuntimeInstalling {
        func prepare() async throws -> ManagedRuntimeReady {
            ManagedRuntimeReady(generationDirectory: "/tmp/Harflow Generation", environment: [
                "PATH": "/tmp/Harflow Generation/bin:/usr/bin", "HOME": "/tmp/Harflow Home",
                "HARFLOW_STATE_ROOT": "/tmp/Harflow Home/.harflow"
            ])
        }

        func checkExisting() async throws -> ManagedRuntimeAvailability { .ready(try await prepare()) }
    }

    private func makeCoordinator() -> ManagedRuntimeCoordinator {
        ManagedRuntimeCoordinator(installer: FailingInstaller())
    }

    @Test func givenReadyGeneration_whenEnvironmentIsRequested_thenCtlBindsToThatGenerationSnapshot() async {
        // given
        let coordinator = ManagedRuntimeCoordinator(installer: ReadyInstaller())
        let repository = ManagedToolEnvironmentRepository(
            coordinator: coordinator, layout: ManagedRuntimeLayout(home: "/tmp/Harflow Home"), baseEnvironment: [:],
            runner: StubProcessRunner(output: stdout(""))
        )
        _ = await coordinator.ensureReady()

        // when / then
        if case .success(let client) = repository.ctl() {
            #expect(client.executable == "/tmp/Harflow Generation/bin/harflow-ctl")
            #expect(client.environment["HARFLOW_STATE_ROOT"] == "/tmp/Harflow Home/.harflow")
        } else {
            Issue.record("expected ctl to bind to the qualified generation")
        }
    }

    @Test func givenFreshManagedEnvironment_whenReadSynchronously_thenPreparationIsNeutralAndNoAmbientRuntimeIsUsed() {
        // given
        let home = "/tmp/Harflow Boundary Fixture"
        let coordinator = makeCoordinator()
        let repository = ManagedToolEnvironmentRepository(
            coordinator: coordinator, layout: ManagedRuntimeLayout(home: home), baseEnvironment: [
                "PATH": "/usr/local/bin", "HOME": "/ambient-home"
            ], runner: StubProcessRunner(output: stdout(""))
        )

        // when / then
        #expect(repository.home == home)
        #expect(repository.tasksDirectory == home + "/.harflow/tasks")
        #expect(repository.environment(toolDirectory: nil)["HOME"] == home)
        #expect(repository.environment(toolDirectory: nil)["HARFLOW_STATE_ROOT"] == home + "/.harflow")
        if case .failure(.refused(let code, _)) = repository.ctl() {
            #expect(code == "managed_runtime_preparing")
        } else {
            Issue.record("expected synchronous ctl access to remain unavailable while preparing")
        }
        if case .failure = repository.locator.locate("harflow-ctl") {
            // Expected: no ambient binary is adopted.
        } else {
            Issue.record("managed locator unexpectedly found an ambient executable")
        }
    }

    @Test func givenManagedReadinessFailure_whenDiscovering_thenFailureIsRetainedAndMappedOnce() async {
        // given
        let coordinator = makeCoordinator()
        let repository = ManagedToolEnvironmentRepository(
            coordinator: coordinator, layout: ManagedRuntimeLayout(home: "/tmp/Harflow Failure Fixture"),
            baseEnvironment: ["PATH": "/usr/local/bin"], runner: StubProcessRunner(output: stdout(""))
        )

        // when
        _ = await repository.discoverEnvironment()

        // then
        #expect(coordinator.state == .failed("fixture runtime failure"))
        if case .failure(.refused(let code, let message)) = repository.ctl() {
            #expect(code == "managed_runtime_failed")
            #expect(message == "fixture runtime failure")
        } else {
            Issue.record("expected failed managed runtime refusal")
        }
        let install = ManagedInstallRepository(coordinator: coordinator, taskListRepository: NullTaskListRepository())
        #expect(install.state == .failed(stage: .harflow, message: "fixture runtime failure"))
        #expect(install.lastCheckMessage == "fixture runtime failure")
        #expect(install.installAnywayBlockedMessage == nil)
    }

    @Test func givenProductionModule_whenInitialized_thenManagedRepositoriesAreWired() {
        // given / when
        Module().initializeModule()

        // then
        #expect(GlobalValues.toolEnvironmentRepository is ManagedToolEnvironmentRepository)
        #expect(GlobalValues.installRepository is ManagedInstallRepository)
    }
}
