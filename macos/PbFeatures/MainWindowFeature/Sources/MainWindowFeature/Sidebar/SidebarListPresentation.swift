import MonitorCore
import PbCommon
import PbRepository
import PbUI

// MARK: - SidebarListPresentation

/// Immutable inputs to the native renderer. Domain ordering remains owned by SidebarVM.
struct SidebarListPresentation: Equatable, Sendable {
    var sections: [SidebarSection]
    var workflowTitles: [String]
    var workflowsExpanded: Bool
    var banner: SidebarBannerPresentation?
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
}

struct SidebarBannerPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let primaryTitle: String?
    let secondaryTitle: String?
    let isBusy: Bool
    let errorText: String?
    let canDismiss: Bool
    let footnote: String?

    init(_ model: InstallBanner.Model) {
        self.title = model.title
        self.detail = model.detail
        self.primaryTitle = model.primaryTitle
        self.secondaryTitle = model.secondaryTitle
        self.isBusy = model.isBusy
        self.errorText = model.errorText
        self.canDismiss = model.canDismiss
        self.footnote = model.footnote
    }

    var model: InstallBanner.Model {
        .init(title: title, detail: detail, primaryTitle: primaryTitle,
              secondaryTitle: secondaryTitle, isBusy: isBusy, errorText: errorText,
              canDismiss: canDismiss, footnote: footnote)
    }
}

struct SidebarListEntry: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case workflowsHeader(expanded: Bool)
        case workflowDefinition(String)
        case heading(String)
        case item(SidebarItem)
        case banner(SidebarBannerPresentation)
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
