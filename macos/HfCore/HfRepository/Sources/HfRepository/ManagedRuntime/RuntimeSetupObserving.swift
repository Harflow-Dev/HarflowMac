import Combine

// MARK: - RuntimeSetupObserving

/// Optional feature adapter surface for shared setup without changing legacy feature mocks.
@MainActor
public protocol RuntimeSetupObserving: Sendable {
    var runtimeSetupState: RuntimeSetupState { get }
    func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never>
    func installRuntime() async
}
