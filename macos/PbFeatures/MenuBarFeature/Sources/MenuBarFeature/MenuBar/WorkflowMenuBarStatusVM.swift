import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository

// MARK: - WorkflowMenuBarUseCase

@Mockable
@MainActor
protocol WorkflowMenuBarUseCase: Sendable {
    func runs() async throws -> [[String: JSONValue]]
}

@MainActor
protocol WorkflowMenuBarPageUseCase {
    func activePage() async throws -> HistoryPage
}

// MARK: - WorkflowMenuBarRow

struct WorkflowMenuBarRow: Identifiable, Equatable {
    let id: String
    let rootID: String
    let name: String
    let status: String
    let detail: String
    let isSettling: Bool
    var isActive: Bool { isSettling || ["starting", "running", "paused", "needs_attention", "needs_input", "cancelling"].contains(status) }
    var isWorking: Bool { isSettling || ["starting", "running", "cancelling"].contains(status) }
    var needsAttention: Bool { ["needs_attention", "needs_input"].contains(status) }
    var statusLabel: String { isSettling ? "Settling" : status.replacingOccurrences(of: "_", with: " ").capitalized }

    init?(_ raw: [String: JSONValue]) {
        guard let id = raw["workflow_run_id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        self.rootID = raw["root_workflow_run_id"]?.stringValue ?? id
        self.name = raw["name"]?.stringValue ?? "Workflow"
        self.status = raw["status"]?.stringValue ?? "unknown"
        self.isSettling = raw["settling"]?.boolValue ?? false
        let decision = raw["decisions"]?.arrayValue?.last?["reason"]?.stringValue
        self.detail = raw["attention_reason"]?.stringValue ?? decision ?? "Workflow"
    }
}

// MARK: - WorkflowMenuBarStatusVM

/// Always-visible status-item state. The label owns its polling lifetime; closing the popover
/// does not stop workflow status from updating. No workflow task event leases are acquired here.
@Observable
@MainActor
final class WorkflowMenuBarStatusVM: ViewModel {
    private(set) var rows: [WorkflowMenuBarRow] = []
    private(set) var errorText: String?
    private(set) var countsLoading = true
    private var catalogActiveCount: Int?
    private var catalogAttentionCount: Int?
    var activeCount: Int { catalogActiveCount ?? (countsLoading ? 0 : rows.filter(\.isActive).count) }
    var attentionCount: Int { catalogAttentionCount ?? (countsLoading ? 0 : rows.filter(\.needsAttention).count) }

    @ObservationIgnored private let useCase: any WorkflowMenuBarUseCase
    /// Whether anyone can see the Monitor: the status item is always on screen, so the poll never
    /// pauses — but with nothing visible it stretches from 2 s to 10 s, since the badge's
    /// needs-input signal is the only thing anyone could notice late.
    @ObservationIgnored private let visibility: any MonitorVisibility
    /// The poll's wait runs on the scheduler seam so tests fire it directly, never a real timer.
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var visibilityWake: AnyCancellable?

    init(useCase: any WorkflowMenuBarUseCase, visibility: any MonitorVisibility, scheduler: any Scheduling) {
        self.useCase = useCase
        self.visibility = visibility
        self.scheduler = scheduler
    }

    /// The poll interval for the current visibility: 2 s while the popover is open or the main
    /// window is visible, else 10 s.
    var pollInterval: TimeInterval {
        (visibility.mainWindowVisible || visibility.menuBarPopoverOpen) ? 2 : 10
    }

    func didAppear() {
        guard poll == nil else { return }
        let token = UUID()
        generation = token
        startPoll(token)
        // The poll stretches to 10 s while nothing is visible; the moment the popover opens or the
        // main window shows, cut any pending wait short and refresh at once.
        visibilityWake = visibility.mainWindowVisiblePublisher()
            .combineLatest(visibility.menuBarPopoverOpenPublisher())
            .map { $0 || $1 }
            .removeDuplicates()
            .dropFirst()
            .filter(\.self)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, poll != nil else { return }
                poll?.cancel()
                startPoll(generation)
            }
    }

    private func startPoll(_ token: UUID) {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh(generation: token)
                do { try await scheduler.wait(for: pollInterval) } catch { return }
            }
        }
    }

    func didDisappear() {
        generation = UUID()
        visibilityWake = nil
        poll?.cancel()
        poll = nil
    }

    func refresh(generation token: UUID? = nil) async {
        do {
            let result: [[String: JSONValue]]
            var activeCount: Int?
            var attentionCount: Int?
            var loadingCounts = false
            if let pages = useCase as? any WorkflowMenuBarPageUseCase {
                let page = try await pages.activePage()
                loadingCounts = !page.countsComplete || page.totalActiveRootCount == nil || page.totalAttentionRootCount == nil
                activeCount = !loadingCounts ? page.totalActiveRootCount : catalogActiveCount
                attentionCount = !loadingCounts ? page.totalAttentionRootCount : catalogAttentionCount
                result = page.items + page.relatedHeaders
            } else { result = try await useCase.runs(); loadingCounts = false }
            guard !Task.isCancelled, token == nil || token == generation else { return }
            let mapped = result.compactMap(WorkflowMenuBarRow.init)
            // A child is part of its owning workflow tree, not another badge item.
            let known = Set(mapped.map(\.id))
            let nextRows = mapped.filter { $0.rootID == $0.id || !known.contains($0.rootID) }.map { row in
                let descendants = mapped.filter { $0.rootID == row.id && $0.id != row.id }
                guard let attention = descendants.first(where: \.needsAttention) ?? descendants.first(where: \.isActive),
                      attention.needsAttention || !row.isActive else { return row }
                return WorkflowMenuBarRow(["workflow_run_id": .string(row.id), "name": .string(row.name),
                    "status": .string(attention.status), "attention_reason": .string("\(attention.name): \(attention.detail)"),
                    "settling": .bool(row.isSettling)]) ?? row
            }
            apply(rows: nextRows, loadingCounts: loadingCounts, activeCount: activeCount, attentionCount: attentionCount)
        } catch {
            guard !Task.isCancelled, token == nil || token == generation else { return }
            // Keep agent monitoring usable with older CLI installations.
            if errorText != "Workflow status unavailable" { errorText = "Workflow status unavailable" }
        }
    }

    /// Assigns only what changed — an unchanged poll recomputes nothing, so it re-renders nothing
    /// either (`WorkflowMenuBarRow` is `Equatable`).
    private func apply(rows nextRows: [WorkflowMenuBarRow], loadingCounts: Bool, activeCount: Int?, attentionCount: Int?) {
        if rows != nextRows { rows = nextRows }
        if countsLoading != loadingCounts { countsLoading = loadingCounts }
        if catalogActiveCount != activeCount { catalogActiveCount = activeCount }
        if catalogAttentionCount != attentionCount { catalogAttentionCount = attentionCount }
        if errorText != nil { errorText = nil }
    }
}
