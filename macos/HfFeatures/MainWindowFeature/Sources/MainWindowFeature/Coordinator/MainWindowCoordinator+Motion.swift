//
//  MainWindowCoordinator+Motion.swift
//  MainWindowFeature
//
//  `motionPaused`: whether the main window is hidden, so the clocks in its root graph stop. See `docs/monitor-performance.md`.
//

import Combine
import Foundation
import HfRepository
import SwiftEnvironment

// MARK: - MainWindowCoordinator + motion

extension MainWindowCoordinator {
    public func startShellObservation() {
        sharedSidebarVM().didAppear()
        subscribeToMotionVisibility()
    }

    public func stopShellObservation() {
        sidebarVM?.didDisappear()
        cancelMotionVisibility()
    }

    /// Stops following the window's visibility; `motionPaused` keeps its last value.
    func cancelMotionVisibility() { motionVisibilitySubscription = nil }

    /// Follows the main window's visibility into `motionPaused`. The publisher can emit off the main thread, so
    /// nothing main-actor runs before `receive(on:)`; a repeated value is not written again.
    func subscribeToMotionVisibility() {
        guard motionVisibilitySubscription == nil else { return }
        let visibility = monitorVisibilityOverride ?? GlobalValues.monitorVisibility
        motionVisibilitySubscription = visibility.mainWindowVisiblePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self else { return }
                let paused = !visible
                if motionPaused != paused { motionPaused = paused }
            }
    }
}
