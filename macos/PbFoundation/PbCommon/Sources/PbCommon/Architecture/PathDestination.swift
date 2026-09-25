//
//  PathDestination.swift
//  PbCommon
//

import Foundation

// MARK: - PathDestination

/// Represents a navigation destination in the coordinator tree.
///
/// Each destination has a unique `pathId` used for routing/debugging and a stable
/// `trackingName` used for screen analytics.
public protocol PathDestination {
    
    /// A unique identifier for the navigation destination.
    var pathId: String { get }
    
    /// A stable analytics screen name for the navigation destination.
    var trackingName: String { get }
    
    /// Checks if this destination is part of another destination.
    /// - Parameter destination: The destination to check against.
    /// - Returns: Whether this destination is part of the specified destination.
    static func isPart(of destination: any PathDestination) -> Bool
}

// MARK: - PathDestination Extension

extension PathDestination {
    
    /// A stable analytics screen name for the navigation destination.
    public var trackingName: String { pathId }
    
    /// Checks if this destination is part of another destination.
    /// - Parameter destination: The destination to check against.
    /// - Returns: Whether this destination is part of the specified destination.
    public static func isPart(of destination: any PathDestination) -> Bool {
        destination is Self
    }
}

extension PathDestination where Self: Identifiable {
    
    /// A unique identifier for the navigation destination.
    public var id: String { pathId }
}

// MARK: - PathDestination Operators

/// Combines two path destinations into an array.
public func + (lhs: any PathDestination, rhs: any PathDestination) -> [any PathDestination] {
    [lhs, rhs]
}

/// Combines two optional path destinations into an array.
public func + (lhs: (any PathDestination)?, rhs: (any PathDestination)?) -> [any PathDestination] {
    let lhs = lhs.map { [$0] } ?? []
    let rhs = rhs.map { [$0] } ?? []
    return lhs + rhs
}

/// Combines a path destination and an optional path destination into an array.
public func + (lhs: any PathDestination, rhs: (any PathDestination)?) -> [any PathDestination] {
    let rhs = rhs.map { [$0] } ?? []
    return [lhs] + rhs
}

/// Combines an optional path destination and a path destination into an array.
public func + (lhs: (any PathDestination)?, rhs: any PathDestination) -> [any PathDestination] {
    let lhs = lhs.map { [$0] } ?? []
    return lhs + [rhs]
}

/// Appends a path destination to an array of path destinations.
public func + (lhs: [any PathDestination], rhs: any PathDestination) -> [any PathDestination] {
    lhs + [rhs]
}

/// Appends an optional path destination to an array of path destinations.
public func + (lhs: [any PathDestination], rhs: (any PathDestination)?) -> [any PathDestination] {
    let rhs = rhs.map { [$0] } ?? []
    return lhs + rhs
}

/// Prepends a path destination to an array of path destinations.
public func + (lhs: any PathDestination, rhs: [any PathDestination]) -> [any PathDestination] {
    [lhs] + rhs
}

/// Prepends an optional path destination to an array of path destinations.
public func + (lhs: (any PathDestination)?, rhs: [any PathDestination]) -> [any PathDestination] {
    let lhs = lhs.map { [$0] } ?? []
    return lhs + rhs
}

// MARK: - CompositeDestination

/// A destination that aggregates child destination types.
///
/// Useful for parent coordinators that need to determine if a given
/// destination belongs to their subtree.
public protocol CompositeDestination: PathDestination {
    
    /// List of child destination types that are part of this composite destination.
    static var children: [any PathDestination.Type] { get }
}

// MARK: - CompositeDestination Extension

extension CompositeDestination {
    
    /// Checks if this destination is part of another destination, including children.
    /// - Parameter destination: The destination to check against.
    /// - Returns: Whether this destination or any of its children is part of the specified destination.
    public static func isPart(of destination: any PathDestination) -> Bool {
        if destination is Self { return true }
        return children.contains { $0.isPart(of: destination) }
    }
}
