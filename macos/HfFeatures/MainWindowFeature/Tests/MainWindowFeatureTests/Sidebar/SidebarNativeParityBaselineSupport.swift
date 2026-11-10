//
// SidebarNativeParityBaselineSupport.swift
// MainWindowFeatureTests
//
// Shared primitives of the unified-outline parity baseline: the keyboard probe set used by the
// fixture's observation pass and by the tests' expectations, and the minimal public-API outline
// data source for the programmatic-alias baseline test.
//

import AppKit

// MARK: - KeyboardProbe

/// The keyboard probes the unified baseline sends to the native outline, each selecting its own
/// anchor row first through its unified entry id, never a hard-coded outline index.
enum KeyboardProbe: String, CaseIterable, Hashable {
    case up, down, home, end, pageUp, pageDown, commandA, `return`, space, letter, runningUp, pendingLaunchesDown

    var characters: String {
        switch self {
        case .up, .runningUp: String(UnicodeScalar(0xF700)!)
        case .down, .pendingLaunchesDown: String(UnicodeScalar(0xF701)!)
        case .home: String(UnicodeScalar(0xF729)!)
        case .end: String(UnicodeScalar(0xF72B)!)
        case .pageUp: String(UnicodeScalar(0xF72C)!)
        case .pageDown: String(UnicodeScalar(0xF72D)!)
        case .commandA: "a"
        case .return: "\r"
        case .space: " "
        case .letter: "b"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .up, .runningUp: 126
        case .down, .pendingLaunchesDown: 125
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .commandA: 0
        case .return: 36
        case .space: 49
        case .letter: 11
        }
    }

    var modifiers: NSEvent.ModifierFlags { self == .commandA ? .command : [] }

    /// The unified entry id each probe selects before sending its key: the Recent anchor for the
    /// ten original probes, the Running task for `runningUp`, and Pending launches for `pendingLaunchesDown`.
    var anchorEntryID: String {
        switch self {
        case .runningUp: "task:abc123"
        case .pendingLaunchesDown: "navigation:pending-launches"
        default: "task:def456"
        }
    }
}

// MARK: - TwoRowOutlineDataSource

@MainActor final class TwoRowOutlineDataSource: NSObject, NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 2 : 0
    }

    func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool { false }

    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any { index }
}
