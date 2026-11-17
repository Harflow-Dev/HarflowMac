import Combine
import Foundation
import HfCommon
import HfRepository
import Mockable
import MonitorCore

// MARK: - WorkflowLibraryUseCase

@Mockable @MainActor
protocol WorkflowLibraryUseCase: Sendable {
    func context() throws -> WorkflowResponseContext
    func isCurrent(_ context: WorkflowResponseContext) -> Bool
    func list(context: WorkflowResponseContext) async throws -> [String: JSONValue]
}

// MARK: - WorkflowLibraryRouting

@Mockable @MainActor
protocol WorkflowLibraryRouting: AnyObject {
    func editLibraryWorkflow(name: String)
    func runLibraryWorkflow(name: String)
    func newLibraryWorkflow(generate: Bool)
}

// MARK: - WorkflowLibraryVM

@Observable @MainActor
final class WorkflowLibraryVM: WorkflowLibraryViewModel {
    private(set) var presentation = WorkflowLibraryPresentation()
    @ObservationIgnored private let useCase: any WorkflowLibraryUseCase
    @ObservationIgnored private weak var routing: (any WorkflowLibraryRouting)?
    @ObservationIgnored private let visibility: any MonitorVisibility
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var context: WorkflowResponseContext?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var visibilitySubscription: AnyCancellable?
    private let incidentSource = "workflow-library"

    init(useCase: any WorkflowLibraryUseCase, routing: any WorkflowLibraryRouting,
         visibility: any MonitorVisibility, scheduler: any Scheduling) {
        self.useCase = useCase
        self.routing = routing
        self.visibility = visibility
        self.scheduler = scheduler
    }

    func didAppear() {
        guard poll == nil else { return }
        if visibilitySubscription == nil {
            visibilitySubscription = visibility.mainWindowVisiblePublisher()
.dropFirst()
                .receive(on: DispatchQueue.main)
.sink { [weak self] visible in
                    if visible { self?.retry() }
                }
        }
        lifecycle = UUID()
        startPoll()
    }

    private func startPoll() {
        let mount = lifecycle
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, lifecycle == mount else { return }
                if visibility.mainWindowVisible { await read(mount: mount) }
                do { try await scheduler.wait(for: 2) } catch { return }
            }
        }
    }

    func didDisappear() {
        lifecycle = UUID()
        poll?.cancel()
        poll = nil
        visibilitySubscription = nil
        reading = false
        context = nil
        loaded = false
        apply(.init())
    }

    func retry() {
        guard poll != nil, !reading else { return }
        // The single poll owns every read. Restarting it cancels a scheduled wait, not a second read.
        poll?.cancel()
        poll = nil
        startPoll()
    }

    func edit(_ row: WorkflowLibraryRow) { route(row) { routing?.editLibraryWorkflow(name: row.name) } }
    func run(_ row: WorkflowLibraryRow) { route(row) { routing?.runLibraryWorkflow(name: row.name) } }
    func create(generate: Bool) { guard poll != nil else { return }; routing?.newLibraryWorkflow(generate: generate) }

    private func route(_ row: WorkflowLibraryRow, action: () -> Void) {
        guard poll != nil, row.mount == lifecycle, row.context == context,
              presentation.rows.contains(row), useCase.isCurrent(row.context) else {
            invalidateScopeIfNeeded()
            return
        }
        action()
    }

    private func invalidateScopeIfNeeded() {
        guard let context, !useCase.isCurrent(context) else { return }
        resetScope(nil)
        retry()
    }

    private func read(mount: UUID) async {
        guard !reading, lifecycle == mount else { return }
        reading = true
        defer { if lifecycle == mount { reading = false } }
        do {
            let captured = try useCase.context()
            if context != captured { resetScope(captured) }
            let response = try await useCase.list(context: captured)
            guard current(mount, captured) else { invalidateScopeIfNeeded(); return }
            let preparation = WorkflowCatalogPreparation.start(response)
            let catalog = try await WorkflowCatalogPreparation.value(of: preparation)
            guard current(mount, captured) else { invalidateScopeIfNeeded(); return }
            try await applyCatalog(catalog, captured: captured, mount: mount)
        } catch is CancellationError {
            return
        } catch {
            guard lifecycle == mount, !Task.isCancelled else { return }
            if let context, !useCase.isCurrent(context) { invalidateScopeIfNeeded(); return }
            failure(error is WorkflowDefinitionCatalog.ReadError
                ? "Saved workflows could not be read completely. Refresh workflows to try again." : error.localizedDescription)
        }
    }

    private func resetScope(_ captured: WorkflowResponseContext?) {
        if context != nil || presentation.error != nil {
            publishViewEvent(.incidentResolved(source: incidentSource))
        }
        context = captured
        loaded = false
        apply(.init())
    }

    private func applyCatalog(_ catalog: WorkflowDefinitionCatalog, captured: WorkflowResponseContext, mount: UUID) async throws {
        switch catalog {
        case .preparing:
            // A pending read does not revoke an earlier actionable failure or successful rows.
            return
        case let .blocked(reason): failure(reason ?? "Workflow catalog is blocked.")
        case let .ready(records):
            let mapping = Task.detached { try WorkflowLibraryPresentation.rows(records, context: captured, mount: mount) }
            let rows = try await withTaskCancellationHandler {
                try await mapping.value
            } onCancel: { mapping.cancel() }
            guard current(mount, captured) else { invalidateScopeIfNeeded(); return }
            loaded = true
            apply(.init(phase: rows.isEmpty ? .empty : .loaded, rows: rows))
            publishViewEvent(.incidentResolved(source: incidentSource))
        }
    }

    private func current(_ mount: UUID, _ captured: WorkflowResponseContext) -> Bool {
        !Task.isCancelled && lifecycle == mount && context == captured && useCase.isCurrent(captured)
    }

    private func failure(_ message: String) {
        apply(.init(phase: loaded ? presentation.phase : .failed, rows: presentation.rows, error: message))
        publishViewEvent(.incident(source: incidentSource, message: message,
                                  retry: AlertAction(title: "Refresh workflows") { [weak self] in self?.retry() }))
    }

    private func apply(_ value: WorkflowLibraryPresentation) {
        if presentation != value { presentation = value }
    }
}
