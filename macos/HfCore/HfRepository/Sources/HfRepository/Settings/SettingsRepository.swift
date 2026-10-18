import Combine
import Foundation
import Mockable
import SwiftEnvironment

// MARK: - SettingsRepository

/// The three `UserDefaults`-backed settings, exactly as `AppModel`'s `@AppStorage` properties:
/// `toolDirectory` (default `""`), `openWindowOnStart` (default `true`), `notifyOnFinish` (default
/// `true`). Keys are never renamed, cleared, or eagerly rewritten; writes go through immediately and
/// are published live, so every reader (the menu bar, Settings) stays in sync through this one
/// repository instance — see decision 11 in the settled plan.
@Mockable
public protocol SettingsRepository: Sendable {

    var toolDirectory: String { get }
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }

    func toolDirectoryPublisher() -> AnyPublisher<String, Never>
    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never>

    func setToolDirectory(_ value: String)
    func setOpenWindowOnStart(_ value: Bool)
    func setNotifyOnFinish(_ value: Bool)
}

// MARK: - NullSettingsRepository

public struct NullSettingsRepository: SettingsRepository {
    public init() {}
    public var toolDirectory: String { "" }
    public var openWindowOnStart: Bool { true }
    public var notifyOnFinish: Bool { true }
    public func toolDirectoryPublisher() -> AnyPublisher<String, Never> { Just("").eraseToAnyPublisher() }
    public func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    public func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    public func setToolDirectory(_: String) {}
    public func setOpenWindowOnStart(_: Bool) {}
    public func setNotifyOnFinish(_: Bool) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global settings repository.
    @GlobalEntry var settingsRepository: any SettingsRepository = NullSettingsRepository()
}
