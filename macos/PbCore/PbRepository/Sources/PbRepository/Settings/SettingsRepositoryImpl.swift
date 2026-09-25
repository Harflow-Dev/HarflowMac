import Combine
import Foundation
import PbUtilities

// MARK: - SettingsRepositoryImpl

/// Wraps a `UserDefaults` (production: `.standard`; tests: an isolated suite) and caches every
/// value in a `@Subjected`, so reads never round-trip through `UserDefaults` after the first one and
/// every subscriber sees the same live value the moment any writer sets it.
public final class SettingsRepositoryImpl: SettingsRepository, @unchecked Sendable {

    /// Exact key names from `AppModel.swift:21-23` — never renamed.
    public static let toolDirectoryKey = "toolDirectory"
    public static let openWindowOnStartKey = "openWindowOnStart"
    public static let notifyOnFinishKey = "notifyOnFinish"

    private let defaults: UserDefaults

    @Subjected private var toolDirectoryValue: String
    @Subjected private var openWindowOnStartValue: Bool
    @Subjected private var notifyOnFinishValue: Bool

    /// Registers the defaults (`register(defaults:)`, never `set`) so a key that was never written
    /// reads its documented default rather than `UserDefaults`' own type default (`false` for a
    /// missing `Bool`, per F8).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.toolDirectoryKey: "",
            Self.openWindowOnStartKey: true,
            Self.notifyOnFinishKey: true
        ])
        _toolDirectoryValue = Subjected(wrappedValue: defaults.string(forKey: Self.toolDirectoryKey) ?? "")
        _openWindowOnStartValue = Subjected(wrappedValue: defaults.object(forKey: Self.openWindowOnStartKey) as? Bool ?? true)
        _notifyOnFinishValue = Subjected(wrappedValue: defaults.object(forKey: Self.notifyOnFinishKey) as? Bool ?? true)
    }

    public var toolDirectory: String { toolDirectoryValue }
    public var openWindowOnStart: Bool { openWindowOnStartValue }
    public var notifyOnFinish: Bool { notifyOnFinishValue }

    public func toolDirectoryPublisher() -> AnyPublisher<String, Never> { $toolDirectoryValue.eraseToAnyPublisher() }
    public func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { $openWindowOnStartValue.eraseToAnyPublisher() }
    public func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { $notifyOnFinishValue.eraseToAnyPublisher() }

    public func setToolDirectory(_ value: String) {
        defaults.set(value, forKey: Self.toolDirectoryKey)
        toolDirectoryValue = value
    }

    public func setOpenWindowOnStart(_ value: Bool) {
        defaults.set(value, forKey: Self.openWindowOnStartKey)
        openWindowOnStartValue = value
    }

    public func setNotifyOnFinish(_ value: Bool) {
        defaults.set(value, forKey: Self.notifyOnFinishKey)
        notifyOnFinishValue = value
    }
}
