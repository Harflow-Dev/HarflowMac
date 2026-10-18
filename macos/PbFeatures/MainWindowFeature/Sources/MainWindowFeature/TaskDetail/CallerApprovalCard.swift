import Foundation
import MonitorCore
import PbRepository
import PbUI
import SwiftEnvironment
import SwiftUI

@MainActor
protocol CallerApprovalUseCase {
    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage
    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest
}

extension CallerApprovalRepository: CallerApprovalUseCase {}

@Observable
@MainActor
final class CallerApprovalController {
    private let useCase: any CallerApprovalUseCase
    private(set) var requests: [CallerApprovalRequest] = []
    private(set) var total = 0
    private(set) var nextCursor: String?
    private(set) var detail: CallerApprovalRequest?
    private(set) var isCurrentDetail = false
    private(set) var selectedID: String?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private var generation = UUID()
    private var inspection = UUID()
    private var targetTask: String?
    private var targetRun: String?

    init(useCase: any CallerApprovalUseCase) { self.useCase = useCase }

    func selectTarget(taskID: String?, workflowRunID: String?) async {
        generation = UUID()
        targetTask = taskID
        targetRun = workflowRunID
        requests = []; total = 0; nextCursor = nil; detail = nil; selectedID = nil; error = nil; isCurrentDetail = false
        isLoading = false; isSubmitting = false
        await refresh()
    }

    func refresh(loadMore: Bool = false) async {
        guard !isLoading, !isSubmitting else { return }
        let token = generation
        isLoading = true
        do {
            var page = try await useCase.page(taskID: targetTask, workflowRunID: targetRun, cursor: loadMore ? nextCursor : nil)
            guard generation == token else { return }
            var values = (loadMore ? requests : []) + page.requests
            let desiredCount = requests.count
            var seenCursors = Set<String>()
            while !loadMore, values.count < desiredCount, let cursor = page.nextCursor, seenCursors.insert(cursor).inserted {
                page = try await useCase.page(taskID: targetTask, workflowRunID: targetRun, cursor: cursor)
                guard generation == token else { return }
                values += page.requests
            }
            var seen = Set<String>()
            requests = values.filter { seen.insert($0.id).inserted }
            requests.sort(by: CallerApprovalPresentation.orderedBefore)
            total = page.total; nextCursor = page.nextCursor
            if let detail, !requests.contains(where: {
                $0.id == detail.id && $0.digest == detail.digest && $0.revision == detail.revision && $0.isPending
            }) { isCurrentDetail = false }
        } catch {
            guard generation == token else { return }
            self.error = String(describing: error)
            isCurrentDetail = false
        }
        if generation == token { isLoading = false }
    }

    func inspect(_ request: CallerApprovalRequest) async {
        guard !isSubmitting else { return }
        selectedID = request.id; detail = nil; error = nil; isCurrentDetail = false
        inspection = UUID()
        let inspectionToken = inspection
        let token = generation
        do {
            let result = try await useCase.detail(request)
            guard generation == token, inspection == inspectionToken, selectedID == request.id else { return }
            guard result.id == request.id, result.taskID == request.taskID, result.digest == request.digest, result.revision == request.revision, result.complete,
                  requests.contains(where: {
                      $0.id == request.id && $0.digest == result.digest && $0.revision == result.revision
                          && $0.text("disposition") == result.text("disposition")
                  }) else {
                error = "The action changed or its full payload is unavailable. Refresh and inspect it again."
                return
            }
            detail = result
            isCurrentDetail = true
        } catch {
            guard generation == token, inspection == inspectionToken, selectedID == request.id else { return }
            self.error = String(describing: error)
        }
    }

    func respond(_ decision: String) async {
        guard !isSubmitting, isCurrentDetail, let request = detail, request.complete, request.isPending, request.isMonitorOwned,
              let deadline = request.deadline, deadline > Date() else { return }
        let token = generation
        isSubmitting = true; error = nil; isCurrentDetail = false
        do {
            let response = try await useCase.respond(request, decision: decision)
            guard generation == token else { return }
            detail = response
        } catch {
            guard generation == token else { return }
            self.error = String(describing: error)
            isCurrentDetail = false
        }
        guard generation == token else { return }
        isSubmitting = false
        await refresh()
    }
}

struct CallerApprovalPanel: View {
    var taskID: String?
    var workflowRunID: String?
    var polls = true
    @State private var controller: CallerApprovalController?
    @GlobalEnvironment(\.toolEnvironmentRepository) private var environment

    static func containsOptIn(_ value: JSONValue) -> Bool {
        if let object = value.objectValue {
            return object["caller_approvals"]?.boolValue == true || object.values.contains(where: containsOptIn)
        }
        return value.arrayValue?.contains(where: containsOptIn) ?? false
    }

    var body: some View {
        Group {
            if let controller, controller.total > 0 || controller.error != nil {
                ScrollView { CallerApprovalCard(controller: controller) }
                    .frame(maxHeight: 320)
                    .padding(PbRadius.Metrics.spacing12)
            }
        }
        .task(id: "\(taskID ?? ""):\(workflowRunID ?? "")") {
            let value = CallerApprovalController(useCase: CallerApprovalRepository(environment: environment))
            controller = value
            await value.selectTarget(taskID: taskID, workflowRunID: workflowRunID)
            while polls, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await value.refresh()
            }
        }
    }
}

enum CallerApprovalPresentation {
    static func priority(_ request: CallerApprovalRequest) -> Int {
        if request.text("delivery") == "delivery_unknown" { return 1 }
        if request.text("disposition") == "pending" || ["reserved", "sending"].contains(request.text("delivery")) { return 0 }
        return 2
    }

    static func orderedBefore(_ lhs: CallerApprovalRequest, _ rhs: CallerApprovalRequest) -> Bool {
        let leftPriority = priority(lhs)
        let rightPriority = priority(rhs)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        let leftTime = lhs.raw["created_at"]?.doubleValue ?? 0
        let rightTime = rhs.raw["created_at"]?.doubleValue ?? 0
        return leftTime == rightTime ? lhs.id < rhs.id : leftTime < rightTime
    }

    static func decisionSummary(_ request: CallerApprovalRequest) -> [String] {
        let original = request.text("decision")
        let effective = request.text("effective_decision")
        let delivered = request.text("delivered_decision")
        var values: [String] = []
        if !original.isEmpty { values.append("Caller decision: \(original)") }
        if !effective.isEmpty, effective != original { values.append("Effective decision: \(effective)") }
        if !delivered.isEmpty, delivered != original { values.append("Delivered decision: \(delivered)") }
        return values
    }
}

struct CallerApprovalCard: View {
    @Bindable var controller: CallerApprovalController
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            HStack {
                Text("Caller approvals (\(controller.total))").font(.pb(.secondary, weight: .semibold))
                Spacer()
                Button("Refresh") { Task { await controller.refresh() } }.disabled(controller.isLoading || controller.isSubmitting)
            }
            ForEach(controller.requests) { request in
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                    Button("Inspect \(request.text("tool_name")) · \(sourceLabel(request))") {
                        Task { await controller.inspect(request) }
                    }.disabled(controller.isSubmitting)
                    Text("\(request.text("disposition")) · Delivery: \(request.text("delivery")) · Observed execution: \(request.text("execution_outcome"))")
                        .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
                    ForEach(CallerApprovalPresentation.decisionSummary(request), id: \.self) { summary in
                        Text(summary).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                    if let detail = controller.detail, controller.selectedID == request.id {
                        actionDetail(detail)
                    }
                }
            }
            if controller.nextCursor != nil {
                Button("Load more requests") { Task { await controller.refresh(loadMore: true) } }.disabled(controller.isLoading || controller.isSubmitting)
            }
            if let error = controller.error { Text(error).font(.pb(.caption)).foregroundStyle(Color.failedRed).textSelection(.enabled) }
        }
        .buttonStyle(.borderless)
        .padding(PbRadius.Metrics.spacing12)
        .background(Color.composerFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
    }

    private func sourceLabel(_ request: CallerApprovalRequest) -> String {
        request.text("workflow_node_id").isEmpty ? request.taskID : request.text("workflow_node_id")
    }

    private func actionDetail(_ request: CallerApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            Text("Working directory: \(request.text("cwd"))\nAccess: \(request.text("freedom"))"
                 + "\nScope: \(request.text("scope"))\nSource task: \(request.taskID)"
)
                .font(.pb(.caption))
.textSelection(.enabled)
            if !request.text("root_workflow_run_id").isEmpty {
                Text("Workflow: \(request.text("root_workflow_run_id"))").font(.pb(.caption)).textSelection(.enabled)
            }
            if !request.text("workflow_execution_id").isEmpty {
                Text("Attempt: \(request.text("workflow_execution_id"))").font(.pb(.caption)).textSelection(.enabled)
            }
            if let deadline = request.deadline { Text("Deadline: \(deadline.formatted())").font(.pb(.caption)) }
            ScrollView([.horizontal, .vertical]) {
                Text(request.raw["action"]?.rendered(pretty: true) ?? "Complete action unavailable")
                    .font(.system(.caption, design: .monospaced))
.textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .accessibilityLabel("Complete exact action")
            }.frame(maxHeight: 220)
            Text("Delivery: \(request.text("delivery")) · Observed execution: \(request.text("execution_outcome"))")
                .font(.pb(.caption))
            if request.isMonitorOwned {
                HStack {
                    Button("Approve once") { Task { await controller.respond("approve") } }
                    Button("Reject", role: .destructive) { Task { await controller.respond("reject") } }
                }
                .disabled(!controller.isCurrentDetail || !request.complete || !request.isPending
                    || controller.isSubmitting || (request.deadline ?? .distantPast) <= Date())
            } else {
                Text("Caller-owned request. Respond through the owning caller's MCP or CLI.").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
    }
}
