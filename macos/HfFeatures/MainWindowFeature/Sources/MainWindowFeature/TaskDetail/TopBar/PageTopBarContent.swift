//
//  PageTopBarContent.swift
//  MainWindowFeature
//
//  What a page-level screen (one that is neither a task nor a group) publishes to the window's top bar: a title and
//  one badge. Pending launches is the first user. Design reference: HarflowDesign 83d820f,
//  `v2/scripts/screens-pending-launches.js` `render()`.
//

import Foundation

// MARK: - PageTopBarContent

/// The principal item's content for a page-level screen.
struct PageTopBarContent: Equatable, Sendable {
    /// The single-line title, 14/20 semibold.
    let title: String
    let badge: TaskBadgeModel
}

// MARK: - Pending launches

extension PageTopBarContent {
    /// The inventory title, also drawn before the screen publishes.
    static let pendingLaunchesTitle = "Pending launches"

    /// The pending launches page with `title`: the launch's own title for a qualified detail, otherwise a fixed one.
    static func pendingLaunches(title: String) -> PageTopBarContent {
        PageTopBarContent(title: title, badge: .pendingLaunch)
    }

    /// The pending launches page before it has published: the inventory title and the badge, so the bar never
    /// shows the shell's text and then restyles.
    static let pendingLaunchesInventory = PageTopBarContent.pendingLaunches(title: pendingLaunchesTitle)
}

// MARK: - TaskBadgeModel page badge

extension TaskBadgeModel {
    /// The pending launch badge: base tone, no icon, no clock.
    static let pendingLaunch = TaskBadgeModel(icon: .hidden, tone: .base, label: "Pending launch", clock: .none, suffix: nil)
}
