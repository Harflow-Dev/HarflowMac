//
//  WaitUntil.swift
//  PbTestUtilities
//

import Foundation

/// Repeatedly checks a condition until it becomes true or the timeout is reached.
/// - Parameters:
///   - timeout: The maximum time to wait, in seconds. Defaults to 3.
///   - condition: A closure that evaluates to a Boolean value.
@MainActor
public func waitUntil(
    timeout: TimeInterval = 3,
    condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
}
