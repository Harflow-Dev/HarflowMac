//
//  TaskPaneController.swift
//  MainWindowFeature
//
//  The standalone task screen's side pane logic: adaptive mode from a measured container width, the defaults a
//  conversation gets the first time it is shown, the person's choices through `TaskPaneStateStore`, the facts-group
//  reveal route and the Escape order. The view only renders what this reports.
//

import Foundation
import Observation
import SwiftUI

// MARK: - TaskPaneController

/// One per mounted standalone task view. Choices persist in the window's `TaskPaneStateStore`, because the
/// coordinator's `.id(conversationID)` reset destroys this object when the selection changes.
@MainActor
@Observable
final class TaskPaneController {

    // MARK: - Types

    /// Whether the pane sits beside the transcript column or over it.
    enum Mode: Equatable, Sendable {
        case split, overlay
    }

    /// The control that started a reveal, so Escape can return focus to it.
    enum Origin: Hashable, Sendable {
        case continuityDetails, notices
    }

    /// A request to move focus into a facts group once its pane is on screen.
    struct FocusRequest: Equatable, Sendable {
        let group: TaskPaneStateStore.FactsGroup
        let token: Int
    }

    /// What the first-show default needs to know, derived by the view from the evidence it holds.
    struct DefaultInput: Equatable, Sendable {
        /// The status and its evidence are settled enough to choose a default. A done task waits for its snapshot.
        var isReady = false
        /// A done task whose snapshot observed an exit opens at split widths; every other state starts closed.
        var opensAtSplit = false
    }

    /// What one Escape press did.
    enum EscapeOutcome: Equatable, Sendable {
        /// Focus leaves the focused facts group; the pane stays.
        case leftFactsGroup(Origin?)
        /// An overlay pane closed.
        case closedOverlay(Origin?)
        /// A pane opened by a reveal closed.
        case closedAfterReveal(Origin?)
        /// Nothing to dismiss.
        case ignored
    }

    // MARK: - Properties

    /// The container width from which the pane is split beside the column rather than over it.
    static let splitMinimumWidth: CGFloat = 900
    /// Widths closer than this are one measurement.
    private static let widthTolerance: CGFloat = 0.5

    /// The tabs a person can reach. `Changes` is reserved ahead of them and is not shown until it has a design.
    static let visibleTabs: [TaskPaneStateStore.Tab] = [.artifacts, .events]

    let conversationID: String
    @ObservationIgnored private let store: TaskPaneStateStore

    /// The measured width of the container that holds the column and the pane, `nil` before the first measurement.
    /// Not observed: a live resize changes it every frame, and only the mode derived from it renders.
    @ObservationIgnored private(set) var containerWidth: CGFloat?
    /// Split at `splitMinimumWidth` and above, overlay below, `nil` before the first measurement. Observed, and
    /// written only when it changes, so a resize re-evaluates readers only when it crosses the threshold.
    private(set) var mode: Mode?
    /// This view's copy of the default applied on first show; the store holds the persistent one.
    @ObservationIgnored private var localAppliedDefault: Bool?
    /// Whether the pane was last opened by a reveal and not since by a person's own toggle or tab choice.
    private(set) var isRevealed = false
    /// The control the current reveal started from.
    private(set) var revealOrigin: Origin?
    /// A pending move of focus into a facts group.
    private(set) var focusRequest: FocusRequest?
    /// A pending return of focus to the control a closed reveal started from.
    private(set) var focusReturn: Origin?

    /// Whether the default applied on first show opens the pane at split widths, `nil` before it is resolved. It
    /// is stored per conversation, so a conversation first shown closed stays closed when revisited. A pane opened
    /// by default is open only while the container is split; a person's own choice is never touched by width.
    var appliedDefaultOpen: Bool? { store.appliedDefault(for: conversationID) ?? localAppliedDefault }

    @ObservationIgnored var reducesMotion = false
    @ObservationIgnored private var defaultInput = DefaultInput()
    @ObservationIgnored private var focusToken = 0

    // MARK: - Lifecycle

    /// Creates the controller for one conversation.
    init(store: TaskPaneStateStore, conversationID: String) {
        self.store = store
        self.conversationID = conversationID
        // A revisit reads the stored default; keep a view-local copy so an eviction while mounted cannot lose it.
        self.localAppliedDefault = store.appliedDefault(for: conversationID)
    }

    // MARK: - Reading

    /// Whether the pane is on screen: the person's choice, else the default (open only at split width), else closed.
    var isOpen: Bool {
        switch store.openChoice(for: conversationID) {
        case .open: true
        case .closed: false
        case .noChoice: (appliedDefaultOpen ?? false) && mode == .split
        }
    }

    /// The selected tab. A stored `Changes` (the store's default, never chosen while the tab is hidden) lands on Events.
    var selectedTab: TaskPaneStateStore.Tab {
        let stored = store.selectedTab(for: conversationID)
        return Self.visibleTabs.contains(stored) ? stored : .events
    }

    /// The expanded facts groups.
    var expandedGroups: Set<TaskPaneStateStore.FactsGroup> { store.expandedGroups(for: conversationID) }

    /// Whether Technical info is expanded in the Events tab.
    var technicalInfoExpanded: Bool { store.technicalInfoExpanded(for: conversationID) }

    /// Expands or collapses Technical info.
    func setTechnicalInfoExpanded(_ expanded: Bool) { store.setTechnicalInfoExpanded(expanded, for: conversationID) }

    /// The Events tab's last recorded scroll offset.
    var eventsScrollOffset: CGFloat? { store.eventsScrollOffset(for: conversationID) }

    // MARK: - Measurement and defaults

    /// Records the measured container width. The container is a flexible view the pane never resizes, so the
    /// measurement does not depend on the mode it selects and settles in one pass.
    func updateContainerWidth(_ width: CGFloat) {
        // The mode follows every measurement, so the breakpoint is exact; the tolerance only decides whether the
        // width is stored and the default re-resolved.
        let next: Mode = width >= Self.splitMinimumWidth ? .split : .overlay
        if mode != next { mode = next }
        if let current = containerWidth, abs(current - width) < Self.widthTolerance { return }
        containerWidth = width
        resolveDefault()
    }

    /// Records what the first-show default may use; applies it once the width is also known.
    func updateDefaultInput(_ input: DefaultInput) {
        defaultInput = input
        resolveDefault()
    }

    /// Marks the conversation as most recently used.
    func touch() { store.touch(conversationID) }

    private func resolveDefault() {
        guard appliedDefaultOpen == nil, defaultInput.isReady, mode != nil else { return }
        localAppliedDefault = defaultInput.opensAtSplit
        store.setAppliedDefault(defaultInput.opensAtSplit, for: conversationID)
    }

    // MARK: - Person's choices

    /// Opens the pane on its current tab.
    func open() {
        dismissReveal()
        focusReturn = nil
        store.setOpenChoice(.open, for: conversationID)
    }

    /// Closes the pane.
    func close() {
        if isRevealed, let revealOrigin { focusReturn = revealOrigin }
        dismissReveal()
        store.setOpenChoice(.closed, for: conversationID)
    }

    /// Opens a closed pane and closes an open one.
    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Selects a tab, which also opens the pane.
    func select(_ tab: TaskPaneStateStore.Tab) {
        guard Self.visibleTabs.contains(tab) else { return }
        dismissReveal()
        focusReturn = nil
        store.setSelectedTab(tab, for: conversationID)
        store.setOpenChoice(.open, for: conversationID)
    }

    /// Expands or collapses one facts group.
    func setGroup(_ group: TaskPaneStateStore.FactsGroup, expanded: Bool) {
        store.setGroup(group, expanded: expanded, for: conversationID)
    }

    /// Records the Events tab's scroll offset so a close or a tab switch keeps the reading position.
    func recordEventsScrollOffset(_ offset: CGFloat) {
        store.setEventsScrollOffset(offset, for: conversationID)
    }

    // MARK: - Reveal and Escape

    /// Opens the pane on Events, expands the group and asks for focus to move into it.
    func revealFacts(group: TaskPaneStateStore.FactsGroup, origin: Origin? = nil) {
        store.setSelectedTab(.events, for: conversationID)
        store.setOpenChoice(.open, for: conversationID)
        store.setGroup(group, expanded: true, for: conversationID)
        isRevealed = true
        revealOrigin = origin
        focusToken += 1
        focusRequest = FocusRequest(group: group, token: focusToken)
    }

    /// Drops a handled focus return.
    func consumeFocusReturn() { focusReturn = nil }

    /// Whether a deferred reveal for `token` may still act: the request is the current one, the pane is open and Events
    /// is the selected tab. The view checks this after yielding, alongside its own task cancellation.
    func isCurrentReveal(token: Int) -> Bool {
        focusRequest?.token == token && isOpen && selectedTab == .events
    }

    /// Drops a handled focus request. A newer request stays.
    func consumeFocusRequest(token: Int) {
        if focusRequest?.token == token { focusRequest = nil }
    }

    /// Applies one Escape press in the order: leave a focused facts group, close an overlay, close a revealed pane.
    /// An `.ignored` result must be side-effect free: a declined event is passed on untouched.
    func handleEscape(groupFocused: Bool) -> EscapeOutcome {
        let origin = revealOrigin
        if groupFocused { return .leftFactsGroup(origin) }
        guard isOpen else { return .ignored }
        if mode == .overlay {
            close()
            return .closedOverlay(origin)
        }
        if isRevealed {
            close()
            return .closedAfterReveal(origin)
        }
        return .ignored
    }

    /// Runs a pane change in the slide animation a person's action gets, or without motion under Reduce Motion.
    /// Defaults applied on first show do not pass through here, so they never animate.
    func animated<Result>(_ change: () -> Result) -> Result {
        withAnimation(reducesMotion ? nil : .easeInOut(duration: Self.slideDuration), change)
    }

    private static var slideDuration: TimeInterval { 0.25 }

    private func dismissReveal() {
        isRevealed = false
        revealOrigin = nil
        focusRequest = nil
    }
}
