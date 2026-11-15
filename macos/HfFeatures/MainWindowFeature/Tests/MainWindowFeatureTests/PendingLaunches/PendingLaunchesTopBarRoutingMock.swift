@testable import MainWindowFeature
import Mockable

// MARK: - PendingLaunchesTopBarRoutingMock

/// The top bar transport a `PendingLaunchesVM` writes to, with every call stubbed. The VM holds it weakly, so the
/// caller keeps the returned mock alive.
@MainActor enum PendingLaunchesTopBarRoutingMock {
    static func make() -> MockPendingLaunchesTopBarRouting {
        let routing = MockPendingLaunchesTopBarRouting()
        given(routing).publishTopBar(.any, tag: .any).willReturn()
        given(routing).clearTopBar(tag: .any).willReturn()
        given(routing).activateTopBar(tag: .any).willReturn()
        given(routing).deactivateTopBar(tag: .any).willReturn()
        given(routing).retryTopBarActivation(tag: .any).willReturn()
        return routing
    }
}
