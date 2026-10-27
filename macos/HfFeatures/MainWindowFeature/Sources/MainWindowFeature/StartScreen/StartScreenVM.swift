import Combine
import Foundation
import HfCommon
import HfRepository
import Mockable
import MonitorCore
import SwiftEnvironment

@Mockable
@MainActor
protocol StartScreenUseCase: Sendable {
    var source: any StartScreenHistorySource { get }
    func changes() -> AnyPublisher<[TaskInfo], Never>
    func errors() -> AnyPublisher<ToolError?, Never>
    func historyState() -> AnyPublisher<HistoryLoadingState, Never>
}

@Mockable
@MainActor
protocol StartScreenRouting: AnyObject {
    func openNewSession()
    func openWorkflowEditor(name: String?)
    func openWorkflowRunner(name: String?)
}

@MainActor
protocol StartScreenViewModel: ViewModel {
    var presentation: StartScreenPresentation { get }
    var loading: Bool { get }
    var definitionsAvailable: Bool { get }
    func didAppear()
    func didDisappear()
    func newSession()
    func newWorkflow()
    func showAll()
    func run(name: String)
    func retry()
}

// MARK: - StartScreenState

struct StartScreenState: Equatable, Sendable {
    var presentation: StartScreenPresentation
    var loading: Bool
    var definitionsAvailable: Bool
}

// MARK: - StartScreenVM

@Observable
@MainActor
final class StartScreenVM: StartScreenViewModel {
    private(set) var state: StartScreenState
    var presentation: StartScreenPresentation { state.presentation }
    var loading: Bool { state.loading }
    var definitionsAvailable: Bool { state.definitionsAvailable }
    @ObservationIgnored private let useCase: any StartScreenUseCase
    @ObservationIgnored private weak var routing: (any StartScreenRouting)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let calendar: @Sendable () -> Calendar
    @ObservationIgnored private let refreshInterval: TimeInterval
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let worker = StartScreenWorker()
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var snapshot: StartScreenSnapshot?
    @ObservationIgnored private var alphabeticalRows: [StartScreenRow] = []
    @ObservationIgnored private var definitionsFailed = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mountID = UUID()
    @ObservationIgnored private var lastStart: TimeInterval?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var clockGeneration = UUID()
    @ObservationIgnored private var lastClockKey: String?

    init(useCase: any StartScreenUseCase, routing: any StartScreenRouting,
         now: @escaping @Sendable () -> Date = { Date() },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         calendar: @escaping @Sendable () -> Calendar = { .current },
         refreshInterval: TimeInterval = 30, tickInterval: Duration = .seconds(1)) {
        self.useCase = useCase
        self.routing = routing
        self.now = now
        self.uptime = uptime
        self.calendar = calendar
        self.refreshInterval = refreshInterval
        self.tickInterval = tickInterval
        let greeting = StartScreenDerivation.greeting(hour: calendar().component(.hour, from: now()))
        self.state = StartScreenState(presentation: StartScreenPresentation(greeting: greeting, status: nil, rows: [], total: 0),
                                      loading: true, definitionsAvailable: false)
    }

    func didAppear() {
        guard !visible else { return }
        visible = true
        mountID = UUID()
        // Missing ownership and explicit null have different meanings in the public contract.
        useCase.changes()
.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidate() }
.store(in: &subscriptions)
        useCase.errors().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        useCase.historyState()
.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidate() }
.store(in: &subscriptions)
        loop = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: tickInterval) } catch { break }
            }
        }
    }

    func didDisappear() {
        guard visible else { return }
        visible = false
        mountID = UUID()
        generation = UUID()
        clockGeneration = UUID()
        loop?.cancel(); loop = nil
        scan?.cancel(); scan = nil
        invalidate()
        subscriptions.removeAll()
    }

    func newSession() { routing?.openNewSession() }
    func newWorkflow() { routing?.openWorkflowEditor(name: nil) }
    func showAll() { routing?.openWorkflowRunner(name: nil) }
    func run(name: String) { routing?.openWorkflowRunner(name: name) }
    func retry() { invalidate() }

    private func invalidate() {
        generation = UUID()
        clockGeneration = UUID()
        snapshot = nil
        lastClockKey = nil
        var next = state
        next.loading = !definitionsFailed
        next.presentation.status = nil
        next.presentation.rows = alphabeticalRows
        apply(next)
    }

    /// One scheduler pulse, also usable with an injected clock in lifecycle tests.
    func tick() async {
        guard visible else { return }
        let date = now()
        let due = lastStart.map { uptime() - $0 >= refreshInterval } ?? true
        if scan == nil, due {
            startScan()
        }
        await rederive(at: date)
    }

    private func rederive(at date: Date) async {
        let calendar = calendar()
        let minute = Int(date.timeIntervalSince1970 / 60)
        let zone = calendar.timeZone
        let key = "\(minute):\(calendar.identifier):\(zone.identifier):\(zone.secondsFromGMT(for: date))"
        guard key != lastClockKey else { return }
        let token = UUID()
        clockGeneration = token
        let id = generation
        let next: StartScreenPresentation
        if let snapshot {
            next = await worker.derive(snapshot: snapshot, now: date, calendar: calendar)
        } else {
            var value = presentation
            value.greeting = StartScreenDerivation.greeting(hour: calendar.component(.hour, from: date))
            next = value
        }
        guard visible, generation == id, clockGeneration == token, !Task.isCancelled else { return }
        lastClockKey = key
        var nextState = state
        nextState.presentation = next
        apply(nextState)
    }

    private func startScan() {
        lastStart = uptime()
        let metricsID = generation
        let mount = mountID
        let source = useCase.source
        let date = now(), calendar = calendar()
        scan = Task { [weak self, worker] in
            let result = await worker.read(source: source, now: date, calendar: calendar) { [weak self] definitions in
                await self?.applyDefinitions(definitions, mount: mount)
            }
            guard let self, !Task.isCancelled, visible, mountID == mount else { return }
            // Only this mounted scan owns this slot. Metrics invalidation never discards definitions.
            defer { if mountID == mount { scan = nil } }
            guard generation == metricsID else { return }
            guard let complete = result.snapshot else { return }
            let next = await worker.derive(snapshot: complete, now: now(), calendar: self.calendar())
            guard !Task.isCancelled, visible, mountID == mount, generation == metricsID else { return }
            clockGeneration = UUID()
            snapshot = complete
            lastClockKey = nil
            apply(StartScreenState(presentation: next, loading: result.preparing, definitionsAvailable: true))
        }
    }

    private func applyDefinitions(_ result: StartScreenDefinitionsResult, mount: UUID) {
        guard visible, mountID == mount, !Task.isCancelled else { return }
        // An identical periodic definition read leaves the retained complete presentation quiet.
        if let saved = result.definitions, let snapshot, snapshot.definitions == saved { return }
        snapshot = nil
        lastClockKey = nil
        clockGeneration = UUID()
        var next = state
        if let presentation = result.presentation {
            definitionsFailed = false
            alphabeticalRows = presentation.rows
            next = StartScreenState(presentation: presentation, loading: true, definitionsAvailable: true)
            apply(next)
            publishViewEvent(.incidentResolved(source: "start-screen.definitions"))
        } else if result.preparing {
            definitionsFailed = false
            next.definitionsAvailable = false
            next.loading = true
            next.presentation.status = nil
            next.presentation.rows = alphabeticalRows
            apply(next)
            publishViewEvent(.incidentResolved(source: "start-screen.definitions"))
        } else {
            definitionsFailed = true
            alphabeticalRows = []
            next.definitionsAvailable = false
            next.presentation.status = nil
            next.presentation.rows = []
            next.presentation.total = 0
            next.loading = false
            apply(next)
            let retry = AlertAction(title: "Retry") { [weak self] in self?.retry() }
            publishViewEvent(.incident(source: "start-screen.definitions", message: "Saved workflows could not be loaded.", retry: retry))
        }
    }

    private func apply(_ next: StartScreenState) {
        if state != next { state = next }
    }

}

@MainActor
final class StartScreenViewRepository: StartScreenUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.toolEnvironmentRepository) private var tools
    @GlobalEnvironment(\.workflowRepository) private var workflows
    @GlobalEnvironment(\.taskListRepository) private var tasks
    var source: any StartScreenHistorySource { StartScreenHistoryRepository(tools: tools, workflows: workflows) }
    func changes() -> AnyPublisher<[TaskInfo], Never> { Self.semanticChanges(tasks.tasksPublisher()) }
    func errors() -> AnyPublisher<ToolError?, Never> { Self.semanticErrors(tasks.listErrorPublisher()) }
    func historyState() -> AnyPublisher<HistoryLoadingState, Never> { Self.semanticHistoryState(tasks.historyStatePublisher()) }

    private nonisolated static let fingerprintQueue = DispatchQueue(label: "dev.harflow.start-screen.fingerprint", qos: .utility)

    /// Initial state is read by the independent history scan; only later semantic changes invalidate it.
    nonisolated static func semanticChanges(_ publisher: AnyPublisher<[TaskInfo], Never>) -> AnyPublisher<[TaskInfo], Never> {
        publisher.receive(on: fingerprintQueue)
            .map { (tasks: $0, fingerprint: fingerprint($0)) }
            .removeDuplicates { $0.fingerprint == $1.fingerprint }
            .dropFirst()
.map(\.tasks)
.eraseToAnyPublisher()
    }

    nonisolated static func semanticErrors(_ publisher: AnyPublisher<ToolError?, Never>) -> AnyPublisher<ToolError?, Never> {
        publisher.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    nonisolated static func semanticHistoryState(_ publisher: AnyPublisher<HistoryLoadingState, Never>) -> AnyPublisher<HistoryLoadingState, Never> {
        publisher.receive(on: fingerprintQueue)
            .map { (state: $0, readiness: StartScreenHistoryReadiness($0)) }
            .removeDuplicates { $0.readiness == $1.readiness }
            .dropFirst()
.map(\.state)
.eraseToAnyPublisher()
    }

    private nonisolated static func fingerprint(_ tasks: [TaskInfo]) -> [[String: JSONValue]] {
        tasks.map { task in
            ["id": .string(task.id), "status": task.raw["status"] ?? .null,
             "finished_at": task.raw["finished_at"] ?? .null,
             "workflow_run_id": task.raw["workflow_run_id"] ?? .string("<unknown>"),
             "workflow_builder": task.raw["workflow_builder"] ?? .null]
        }
    }
}

// MARK: - StartScreenHistoryReadiness

private struct StartScreenHistoryReadiness: Equatable {
    var catalogState: CatalogState
    var bootstrapPending: Bool
    var historyIncomplete: Bool
    var authorityIncomplete: Bool
    var countsComplete: Bool

    init(_ state: HistoryLoadingState) {
        self.catalogState = state.catalogState
        self.bootstrapPending = state.bootstrapPending
        self.historyIncomplete = state.historyIncomplete
        self.authorityIncomplete = state.authorityIncomplete
        self.countsComplete = state.countsComplete
    }
}
