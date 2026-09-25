//
//  Publisher+Extensions.swift
//  PbUtilities
//
//  Only the members `Subjected` and the Monitor's repositories/VMs actually need are kept.
//

import Combine
import Foundation

// MARK: - Publisher where Failure == Never

/// Publisher helpers for non-failing streams.
public extension Publisher where Failure == Never {
    
    // MARK: - Public Methods
    
    /// Assigns emitted values to a property using a weak object reference.
    ///
    /// - Parameters:
    ///   - keyPath: Writable key path on the target object.
    ///   - object: Target object to assign into.
    /// - Returns: A cancellable subscription.
    @inlinable func weakAssign<Root: AnyObject>(to keyPath: ReferenceWritableKeyPath<Root, Output>, on object: Root) -> AnyCancellable {
        sink { [weak object] output in
            object?[keyPath: keyPath] = output
        }
    }
}

public extension Publisher {
    
    // MARK: - Public Methods
    
    /// Taps into the publisher to perform an action when it emits a value.
    ///
    /// - Parameter handler: Closure to execute with the emitted value.
    /// - Returns: A publisher that performs the action when it emits a value.
    @inlinable func tapOutput(_ handler: @escaping (Output) -> Void) -> Publishers.HandleEvents<Self> {
        handleEvents(receiveOutput: handler)
    }
    
    /// Assigns emitted values to a property using a weak object reference while keeping the publisher chain alive.
    ///
    /// Use this when a value should update local cached state and still participate in downstream publisher composition.
    /// - Parameters:
    ///   - keyPath: Writable key path on the target object.
    ///   - object: Target object to assign into.
    /// - Returns: A publisher that performs the weak assignment when it emits a value.
    func tapWeakAssign<Root: AnyObject>(to keyPath: ReferenceWritableKeyPath<Root, Output>, on object: Root) -> Publishers.HandleEvents<Self> {
        tapOutput { [weak object] output in
            object?[keyPath: keyPath] = output
        }
    }
}

// MARK: - Publisher (internal helper)

extension Publisher {
    
    // MARK: - Internal Methods
    
    /// Shared by `Subjected`'s `assign(to:)`/`uniqueAssign(to:)` helpers.
    @inlinable func inspectOutput(_ handler: @escaping (Output) -> Void) -> Publishers.HandleEvents<Self> {
        handleEvents(receiveOutput: handler)
    }
}
