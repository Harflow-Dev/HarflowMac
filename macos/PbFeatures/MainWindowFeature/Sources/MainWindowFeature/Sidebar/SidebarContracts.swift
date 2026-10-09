import AppKit
import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities
import SwiftUI

// MARK: - SidebarUseCase

/// The sidebar's data needs over `TaskListRepository`.
@Mockable
@MainActor
protocol SidebarUseCase: Sendable {

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never>
    func hasListedPublisher() -> AnyPublisher<Bool, Never>
    /// Titles load off-main, separately from the listing itself (F4-11/MS-LIST-5) — a row must
    /// refresh when one arrives even though `tasks` itself did not change.
    func titlesPublisher() -> AnyPublisher<[String: String], Never>

    var tasks: [TaskInfo] { get }
    var listError: ToolError? { get }
    var hasListed: Bool { get }
    var connectionLine: String { get }

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { get }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never>

    func title(_ taskID: String) -> String

    // MARK: Install (settled plan, section 5)

    func installStatePublisher() -> AnyPublisher<InstallState, Never>
    var installState: InstallState { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>
    var lastCheckMessage: String? { get }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never>
    var installAnywayBlockedMessage: String? { get }
    /// Classifies `error` against the currently located `polybridge-ctl`/`polybridge-setup`
    /// presence; `nil` when `error` isn't an install need.
    func installNeed(for error: ToolError) -> InstallNeed?
    /// Where the next install would land, for confirmation-dialog copy only.
    func installDestination() -> String?
    func install() async
    func installUvThenPolybridge() async
    func retry() async
    func checkAgain() async
    @discardableResult
    func installAnyway() async -> Bool
    func reset()
}

// MARK: - PendingReveal

/// A navigation-triggered request to reveal (expand the ancestors of) a task in the sidebar's tree —
/// owned by `MainWindowCoordinator` (settled plan, Design point 5's "coordinator owns the pending
/// reveal") rather than by `SidebarVM`, so it survives a window close/reopen even though the sidebar
/// is unsubscribed while hidden. `requestID` is fresh on every request, repeats included — plain
/// `selection` reuses the same value on a repeated navigation to an already-selected task, and its
/// own `didSet` drops that repeat (see `MainWindowCoordinator.selection`), so a `PassthroughSubject`
/// keyed only on the task id would silently do the same. A fresh id per request sidesteps that.
struct PendingReveal: Equatable, Sendable {
    let taskID: String
    let requestID: UUID
}

// MARK: - SidebarRouting

/// Navigation the sidebar performs, plus the read side of the same selection state
/// `MainWindowCoordinator` owns (decision in this dispatch's `AGENTS.md`): the sidebar's
/// `List(selection:)` binding needs to reflect a selection made elsewhere (e.g. "Open parent" in
/// the still-app-target `TaskDetailView`), not just its own taps.
@Mockable
@MainActor
protocol SidebarRouting: Sendable {
    var selection: MonitorDestination? { get }
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never>
    /// `nil` clears the selection — `List(selection:)` writes `nil` on deselection, and the old
    /// `List(selection: $model.selection)` accepted that directly.
    func select(_ destination: MonitorDestination?)
    func openNewSession()

    // MARK: Pending reveal (settled plan, Design point 5)

    /// The latest unconsumed navigation-triggered reveal, or `nil`. Read on `didAppear()` so a
    /// reveal requested while the sidebar was unsubscribed (window closed) is not lost.
    var pendingReveal: PendingReveal? { get }
    func revealPublisher() -> AnyPublisher<PendingReveal, Never>
    /// Marks `requestID`'s reveal consumed — a no-op if it has already been superseded by a later
    /// one (a fresh request replaces the pending value before this is called).
    func consumeReveal(requestID: UUID)
}
