import Combine
import Foundation
import Mockable
import SwiftEnvironment

// MARK: - SettingsRepository

/// The `UserDefaults`-backed settings: `openWindowOnStart` (default `true`), `notifyOnFinish`
/// (default `true`), `notifyOnNeedsYou` (default `true`) and the app-wide appearance (default
/// `.system`). Keys are never renamed, cleared, or eagerly rewritten; writes go through immediately and
/// are published live, so every reader (the menu bar, Settings) stays in sync through this one
/// repository instance — see decision 11 in the settled plan. Every member is a protocol
/// requirement with no extension default, so a call through the existential always reaches the
/// conforming type.
@Mockable
public protocol SettingsRepository: Sendable {

    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
    var notifyOnNeedsYou: Bool { get }
    var appAppearance: AppAppearance { get }

    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnNeedsYouPublisher() -> AnyPublisher<Bool, Never>
    func appAppearancePublisher() -> AnyPublisher<AppAppearance, Never>

    func setOpenWindowOnStart(_ value: Bool)
    func setNotifyOnFinish(_ value: Bool)
    func setNotifyOnNeedsYou(_ value: Bool)
    func setAppAppearance(_ value: AppAppearance)
}

// MARK: - NullSettingsRepository

public struct NullSettingsRepository: SettingsRepository {
    public init() {}
    public var openWindowOnStart: Bool { true }
    public var notifyOnFinish: Bool { true }
    public var notifyOnNeedsYou: Bool { true }
    public var appAppearance: AppAppearance { .system }
    public func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    public func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    public func notifyOnNeedsYouPublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    public func appAppearancePublisher() -> AnyPublisher<AppAppearance, Never> { Just(.system).eraseToAnyPublisher() }
    public func setOpenWindowOnStart(_: Bool) {}
    public func setNotifyOnFinish(_: Bool) {}
    public func setNotifyOnNeedsYou(_: Bool) {}
    public func setAppAppearance(_: AppAppearance) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global settings repository.
    @GlobalEntry var settingsRepository: any SettingsRepository = NullSettingsRepository()
}
