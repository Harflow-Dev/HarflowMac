import HfCommon
import HfRepository
import MonitorCore

// MARK: - SidebarListPresentation

/// Immutable inputs to the native renderer. Domain ordering remains owned by SidebarVM.
struct SidebarListPresentation: Equatable, Sendable {
    enum Role: Equatable, Sendable { case combined, running, recent, unified }
    var sections: [SidebarSection]
    var workflowTitles: [String]
    var workflowsExpanded: Bool
    var listError: String?
    var skeleton: Bool
    var taskHistory: HistoryLoadingState
    var workflowHistory: HistoryLoadingState
    var emptyMessage: String?
    var fadingIDs: Set<String>
    var minimumRowHeight: Double
    var historyRevision: Int
    var historyToken: String
    var transitionEpoch: Int = 0
    var needsYouBadge: NeedsYouBadge = .none
    /// Explicit render role: production scrolls `.unified` (navigation, Running and Recent work in
    /// one bounded outline); `.combined`, `.running` and `.recent` remain the legacy fixture roles.
    var role: Role = .combined
}

struct SidebarListEntry: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case navigation(SidebarNavigationEntry)
        case needsYou(NeedsYouBadge)
        case statistics
        case resourceSlots
        case workflowsHeader(expanded: Bool)
        case workflowDefinition(String)
        case heading(String)
        case item(SidebarItem)
        case error(String)
        case skeleton
        case history(String, HistoryLoadingState)
        case empty(String)
        case sentinel
    }

    let id: String
    let content: Content
    var isFading = false
    var minimumHeight: Double = 0
    var incarnation: Int = 0
    var displayID: SidebarDisplayID

    init(id: String, content: Content, isFading: Bool = false, minimumHeight: Double = 0,
         incarnation: Int = 0, displayID: SidebarDisplayID? = nil) {
        self.id = id
        self.content = content
        self.isFading = isFading
        self.minimumHeight = minimumHeight
        self.incarnation = incarnation
        self.displayID = displayID ?? .init(logicalID: id)
    }

    var nativeID: SidebarNativeIdentity { .init(displayID: displayID, incarnation: incarnation) }

    var destination: MonitorDestination? {
        guard !isFading else { return nil }
        switch content {
        case .navigation(let navigation): return navigation.destination
        case .needsYou: return .needsYou(itemID: nil)
        case .statistics: return .statistics
        case .resourceSlots: return .resourceSlots
        case .item(let item): return item.destination
        case .workflowDefinition(let title): return .workflow(title)
        default: return nil
        }
    }

    var isHeading: Bool {
        switch content {
        case .workflowsHeader, .heading: true
        default: false
        }
    }
}

struct SidebarNativeIdentity: Hashable, Sendable {
    let displayID: SidebarDisplayID
    let incarnation: Int
}

/// One unified-surface navigation row (M04 `.hd-m04-sidebar-scroll`): title, exact rail artwork,
/// a real destination, an optional Needs you badge and an optional keyboard shortcut hint.
struct SidebarNavigationEntry: Equatable, Sendable {
    let id: String
    let title: String
    let artwork: SidebarNavigationArtwork
    let destination: MonitorDestination
    var badge: NeedsYouBadge = .none
    var shortcut: String?

    /// The unified scroll's navigation order: New task, Needs you, Workflows, Resources, Statistics, Pending launches.
    static func unifiedEntries(badge: NeedsYouBadge) -> [SidebarNavigationEntry] {
        [
            .init(id: "navigation:new-task", title: "New task", artwork: .plus,
                  destination: .newSession, shortcut: "⌘N"),
            .init(id: "navigation:needs-you", title: "Needs you", artwork: .hand,
                  destination: .needsYou(itemID: nil), badge: badge),
            .init(id: "navigation:workflows", title: "Workflows", artwork: .workflow,
                  destination: .workflowLibrary),
            .init(id: "navigation:resources", title: "Resources", artwork: .gauge,
                  destination: .resourceSlots),
            .init(id: "navigation:statistics", title: "Statistics", artwork: .chart,
                  destination: .statistics),
            .init(id: "navigation:pending-launches", title: "Pending launches", artwork: .clock,
                  destination: .pendingLaunches)
        ]
    }
}

struct SidebarDisplayID: Hashable, Sendable {
    /// Item logical IDs have task/workflow/group prefixes, so this owner cannot be a root ID.
    static let orphanOwnerID = "$sidebar-orphan"
    let logicalID: String
    var ownerID: String?
    var occurrence = 0
}

struct SidebarNativeTransition: Sendable {
    let epoch: Int
    let fading: Bool
    let ended: Bool
}
