//
//  Coordinator.swift
//  PbCommon
//

import Foundation
import Mockable
import SwiftUI

// MARK: - Typealias

/// A coordinator that is both a child of a parent and a parent of children.
public typealias BranchCoordinator = ChildCoordinator & ParentCoordinator

/// A coordinator that is a child and can produce a view.
public typealias ViewChildCoordinator = ChildCoordinator & ViewCoordinator

// MARK: - Coordinator

/// Base protocol for all coordinators.
///
/// A coordinator manages navigation state and delegates view building
/// to concrete implementations. Every coordinator exposes a `path`
/// representing its position in the navigation tree.
@Mockable
public protocol Coordinator: AnyObject, CustomStringConvertible {
    
    /// The path representing the coordinator's current position in the navigation tree.
    @MainActor var path: [PathDestination] { get }
    
    /// The full path including child coordinator paths.
    @MainActor var fullPath: [PathDestination] { get }
    
    /// Restarts the coordinator.
    @MainActor func restart()
    
    /// Stops the coordinator.
    @MainActor func stop()
    
    /// Handles a URL for deep linking.
    /// - Parameter url: The URL to handle.
    /// - Returns: Whether the URL was handled.
    @MainActor @discardableResult func handle(url: URL) -> Bool
    
    /// Handles a specific navigation path.
    /// - Parameter path: The path destination to handle.
    @MainActor func handle(path: PathDestination)
}

// MARK: - Coordinator Extension

extension Coordinator {
    
    /// A textual representation of the coordinator.
    public var description: String {
        String(reflecting: Self.self) + "_\(Unmanaged.passUnretained(self).toOpaque())"
    }
    
    /// The full path including child coordinator paths.
    @MainActor
    public var fullPath: [PathDestination] { path }
    
    /// The root coordinator in the current hierarchy.
    @MainActor
    public var rootCoordinator: Coordinator {
        var current: Coordinator = self
        while let child = current as? ChildCoordinator {
            current = child.parent
        }
        return current
    }
    
    /// Whether this coordinator is a root coordinator.
    @MainActor
    var isRoot: Bool { !(self is ChildCoordinator) }
    
    /// Whether this coordinator has a parent coordinator.
    @MainActor
    public var hasParent: Bool {
        self is ChildCoordinator
    }
    
    /// Whether this coordinator currently has an active child.
    @MainActor
    public var hasChild: Bool {
        guard let parent = self as? ParentCoordinator else { return false }
        return parent.activeChild != nil
    }
    
    /// Restarts the coordinator.
    public func restart() {}
    
    /// Stops the coordinator.
    public func stop() {}
    
    /// Handles a specific navigation path.
    public func handle(path: any PathDestination) {}
    
    /// Routes to a specific destination starting from the root coordinator.
    /// - Parameter destination: The destination to route to.
    @MainActor
    public func route(to destination: any PathDestination) {
        rootCoordinator.handle(path: destination)
    }
}

// MARK: - ViewCoordinator

/// A coordinator that can produce a SwiftUI view.
public protocol ViewCoordinator: Observable, Coordinator {
    
    /// Produces the SwiftUI view for this coordinator.
    @MainActor func start() -> AnyView
    
    /// Produces the SwiftUI view for this coordinator and handles a specific path.
    /// - Parameter path: The path destination to handle.
    @MainActor func start(with path: PathDestination) -> AnyView
}

// MARK: - ViewCoordinator Extension

extension ViewCoordinator {
    
    /// Produces the SwiftUI view for this coordinator and handles a specific path.
    /// - Parameter path: The path destination to handle.
    @MainActor
    public func start(with path: PathDestination) -> AnyView {
        defer { handle(path: path) }
        return start()
    }
    
    /// Produces the SwiftUI view for this coordinator and handles an optional path.
    /// - Parameter path: The optional path destination to handle.
    @MainActor
    public func start(with path: PathDestination?) -> AnyView {
        guard let path else { return start() }
        return start(with: path)
    }
}

// MARK: - ChildCoordinator

/// A coordinator that has a parent coordinator.
public protocol ChildCoordinator: Coordinator {
    
    /// The parent coordinator.
    @MainActor var parent: Coordinator { get }
}

// MARK: - ChildCoordinator Extension

public extension ChildCoordinator {
    
    /// Removes this coordinator from its parent.
    @MainActor func removeFromParent() {
        guard let parent = parent as? ParentCoordinator else { return }
        parent.childDidStop(self)
    }
    
    /// Stops this coordinator by removing it from its parent.
    @MainActor func stop() {
        removeFromParent()
    }
    
    /// Handles a URL by delegating to the root coordinator.
    /// - Parameter url: The URL to handle.
    /// - Returns: Whether the URL was handled.
    @MainActor @discardableResult func handle(url: URL) -> Bool {
        rootCoordinator.handle(url: url)
    }
}

// MARK: - ParentCoordinator

/// A coordinator that manages child coordinators.
public protocol ParentCoordinator: Coordinator {
    
    /// The currently active child coordinator, if any.
    @MainActor var activeChild: ChildCoordinator? { get }
    
    /// Notifies the parent that a child coordinator has stopped.
    /// - Parameter child: The child coordinator that stopped.
    @MainActor func childDidStop(_ child: ChildCoordinator)
}

// MARK: - ParentCoordinator Extension

public extension ParentCoordinator {
    
    /// The full path including child coordinator paths.
    @MainActor var fullPath: [PathDestination] {
        if let childParent = activeChild as? ParentCoordinator {
            path + childParent.fullPath
        } else {
            path + (activeChild?.path ?? [])
        }
    }
}
