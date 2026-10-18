import Foundation
@testable import HfRepository
import SwiftEnvironment
import Testing

@Suite("Managed runtime boundary", .serialized)
@MainActor
struct ManagedRuntimeBoundaryTests {
    @Test("managed tool environment is an explicit unavailable boundary")
    func toolEnvironmentDoesNotDiscoverOrReadHistory() async {
        let repository = ManagedToolEnvironmentRepository()

        #expect(repository.home == "/dev/null")
        #expect(repository.tasksDirectory == "/dev/null/.harflow/tasks")
        #expect(repository.discovery == DiscoveryResult(loginPath: nil, uv: nil))
        #expect(repository.environment(toolDirectory: "/tmp/ignored").isEmpty)
        if case .failure = repository.locator.locate("harflow-ctl") {
            // Expected: the managed boundary never discovers executables.
        } else {
            Issue.record("managed locator unexpectedly found harflow-ctl")
        }
        #expect(await repository.discoverEnvironment() == repository.discovery)
        if case .failure(.notFound(let tool, _)) = repository.ctl() {
            #expect(tool == "Managed Harflow runtime unavailable")
        } else {
            Issue.record("managed ctl unexpectedly became available")
        }
        if case .failure(.notFound(let tool, _)) = repository.setup() {
            #expect(tool == "Managed Harflow runtime unavailable")
        } else {
            Issue.record("managed setup unexpectedly became available")
        }
    }

    @Test("managed install remains failed and never launches or changes state")
    func installEntryPointsAreNoOps() async {
        let repository = ManagedInstallRepository()
        let initial = repository.state

        #expect(repository.destination() == nil)
        #expect(repository.lastCheckMessage == ManagedInstallRepository.unavailableMessage)
        #expect(repository.installAnywayBlockedMessage == ManagedInstallRepository.unavailableMessage)
        await repository.install()
        await repository.installUvThenHarflow()
        await repository.retry()
        await repository.checkAgain()
        #expect(await repository.installAnyway() == false)
        repository.reset()
        #expect(repository.state == initial)
        #expect(repository.lastCheckMessage == ManagedInstallRepository.unavailableMessage)
    }

    @Test("production module wires managed repositories")
    func moduleWiresManagedImplementations() {
        Module().initializeModule()
        #expect(GlobalValues.toolEnvironmentRepository is ManagedToolEnvironmentRepository)
        #expect(GlobalValues.installRepository is ManagedInstallRepository)
    }
}
