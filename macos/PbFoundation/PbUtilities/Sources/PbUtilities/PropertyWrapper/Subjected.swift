//
//  Subjected.swift
//  PbUtilities
//

import Combine
import Foundation

/// A thread-safe property wrapper that wraps a `CurrentValueSubject<Value, Never>`, providing a reactive and sendable alternative to `@Published`.
///
/// `@Subjected` is useful for non-SwiftUI Combine-based architectures where:
/// - You need thread-safe access to values.
/// - You want fine-grained control over Combine publishers.
/// - You want to avoid memory retention issues common with `@Published`.
///
/// It allows access to the current value via `wrappedValue`, supports Combine subscriptions by conforming to `Publisher`, and provides `assign(to:)` and `uniqueAssign(to:)` helpers for assigning publisher outputs.
///
/// Access is serialized with an `NSRecursiveLock` rather than a concurrent `DispatchQueue` barrier. A plain recursive mutex is safe to acquire from Swift concurrency contexts (actors / the cooperative thread pool), whereas a blocking `DispatchQueue.sync(flags: .barrier)` parks a cooperative thread and can starve the pool. The recursive lock also lets a subscriber synchronously read or write the same `Subjected` during delivery without self-deadlocking.
///
/// This property wrapper does **not** integrate with `ObservableObject`, making it more suitable for services, coordinators, and non-SwiftUI contexts.
@propertyWrapper
public final class Subjected<Value>: @unchecked Sendable, Hashable {
    
    // MARK: - Private Properties
    
    private let lock = NSRecursiveLock()
    private let subject: CurrentValueSubject<Value, Never>
    
    // MARK: - Public Properties
    
    /// The current value of the subject. Thread-safe getter and setter.
    public var wrappedValue: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return subject.value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            subject.send(newValue)
        }
    }
    
    /// Returns `self`, enabling access to the publisher and helper methods.
    public var projectedValue: Subjected<Value> { self }
    
    // MARK: - Fileprivate Properties
    
    fileprivate var cancellables: Set<AnyCancellable> = []
    
    // MARK: - Public Methods
    
    /// Initializes the subject with an initial value.
    /// - Parameter wrappedValue: The initial value to store and publish.
    public init(wrappedValue: Value) {
        self.subject = CurrentValueSubject(wrappedValue)
    }
    
    // MARK: - Internal Methods
    
    deinit {
        cancellables.forEach { $0.cancel() }
    }
    
    // MARK: - Public Methods
    
    /// Compares two `Subjected` instances for equality based on their identity.
    public static func == (lhs: Subjected<Value>, rhs: Subjected<Value>) -> Bool {
        lhs === rhs
    }
    
    /// Hashes the instance identity.
    /// - Parameter hasher: The hasher to use.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - Subjected + Publisher

extension Subjected: Publisher {
    
    // MARK: - Subjected.PublisherAliases
    
    /// The published output type.
    public typealias Output = Value
    /// The failure type, always `Never`.
    public typealias Failure = Never
    
    // MARK: - Public Methods
    
    /// Subscribes the provided subscriber to value updates.
    public func receive<S>(subscriber: S) where S: Subscriber, Never == S.Failure, Value == S.Input {
        lock.lock()
        defer { lock.unlock() }
        subject.receive(subscriber: subscriber)
    }
}

// MARK: - Subjected + Encodable

extension Subjected: Encodable where Value: Encodable {
    
    // MARK: - Public Methods
    
    /// Encodes the wrapped value to the given encoder.
    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

// MARK: - Subjected + Decodable

extension Subjected: Decodable where Value: Decodable {
    
    // MARK: - Public Methods
    
    /// Initializes the subject by decoding a value from the given decoder.
    public convenience init(from decoder: Decoder) throws {
        let value = try Value(from: decoder)
        self.init(wrappedValue: value)
    }
}

// MARK: - Publisher + Subjected Assign

/// Assignment helpers from publishers to `Subjected` wrappers.
public extension Publisher {
    
    // MARK: - Public Methods
    
    /// Assigns values from the publisher to the given `Subjected` instance.
    /// - Returns: A shared publisher forwarding the same values.
    @discardableResult
    func assign(to subject: Subjected<Output>) -> AnyPublisher<Output, Failure> {
        let shared = inspectOutput { [weak subject] output in
            subject?.wrappedValue = output
        }.share()
        defer { shared.sink { _ in } receiveValue: { _ in }.store(in: &subject.cancellables) }
        return shared.eraseToAnyPublisher()
    }
}

// MARK: - Publisher + Subjected Unique Assign

/// Unique-assignment helpers for equatable publisher outputs.
public extension Publisher where Output: Equatable {
    
    // MARK: - Public Methods
    
    /// Assigns values to the `Subjected` only if the value differs from the current one.
    /// - Returns: A shared publisher forwarding unique values.
    @discardableResult
    func uniqueAssign(to subject: Subjected<Output>) -> AnyPublisher<Output, Failure> {
        let shared = inspectOutput { [weak subject] output in
            guard let subject, subject.wrappedValue != output else { return }
            subject.wrappedValue = output
        }.share()
        defer { shared.sink { _ in } receiveValue: { _ in }.store(in: &subject.cancellables) }
        return shared.eraseToAnyPublisher()
    }
}
