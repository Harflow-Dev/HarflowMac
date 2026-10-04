import Foundation
import Mockable
import MonitorCore
import PbCommon

// MARK: - WorkflowMenuBarUseCase

@Mockable
@MainActor
protocol WorkflowMenuBarUseCase: Sendable {
    func runs() async throws -> [[String: JSONValue]]
}

// MARK: - WorkflowMenuBarRow

struct WorkflowMenuBarRow: Identifiable, Equatable {
    let id: String
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
    var activeCount: Int { rows.filter(\.isActive).count }
    var attentionCount: Int { rows.filter(\.needsAttention).count }

    @ObservationIgnored private let useCase: any WorkflowMenuBarUseCase
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(useCase: any WorkflowMenuBarUseCase) { self.useCase = useCase }

    func didAppear() {
        guard poll == nil else { return }
        let token = UUID()
        generation = token
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh(generation: token)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func didDisappear() {
        generation = UUID()
        poll?.cancel()
        poll = nil
    }

    func refresh(generation token: UUID? = nil) async {
        do {
            let result = try await useCase.runs()
            guard !Task.isCancelled, token == nil || token == generation else { return }
            rows = result.compactMap(WorkflowMenuBarRow.init)
            errorText = nil
        } catch {
            guard !Task.isCancelled, token == nil || token == generation else { return }
            // Keep agent monitoring usable with older CLI installations.
            errorText = "Workflow status unavailable"
        }
    }
}
