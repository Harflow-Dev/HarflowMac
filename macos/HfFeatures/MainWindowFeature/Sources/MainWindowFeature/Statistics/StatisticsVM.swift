import Foundation
import HfCommon
import HfRepository
import Mockable
import SwiftEnvironment

// MARK: - StatisticsUseCase

@Mockable
@MainActor
protocol StatisticsUseCase {
    var repository: any StatisticsRepository { get }
}

@MainActor
final class StatisticsViewRepository: StatisticsUseCase {
    @GlobalEnvironment(\.statisticsRepository) private var statistics
    var repository: any StatisticsRepository { statistics }
}

struct StatisticsSelection: Equatable, Sendable {
    var range: StatisticsRange = .thirty
    var measure: StatisticsMeasure = .time
    var list: StatisticsList = .workflows
    var repository: String?
    var harness: String?
    var requestedModel: String?
    var expanded: Set<String> = []
    var nodes: String?
}

// MARK: - StatisticsVM

@Observable
@MainActor
final class StatisticsVM: StatisticsViewModel {
    private(set) var presentation = StatisticsPresentation()
    @ObservationIgnored private let useCase: any StatisticsUseCase
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: @Sendable () -> Calendar
    @ObservationIgnored private let worker = StatisticsHistoryWorker()
    @ObservationIgnored private var selection = StatisticsSelection()
    @ObservationIgnored private var snapshot: StatisticsSnapshot?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var projection: Task<Void, Never>?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var projectionGeneration = UUID()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var refreshFailure: String?

    init(
        useCase: any StatisticsUseCase,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .current }
    ) {
        self.useCase = useCase; self.now = now; self.calendar = calendar
    }

    func didAppear() {
        guard !mounted else { return }; mounted = true; reload()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, mounted else { return }
                reload()
            }
        }
    }

    func didDisappear() {
        guard mounted else { return }; mounted = false; generation = UUID()
        task?.cancel(); task = nil; projection?.cancel(); projection = nil
        refresh?.cancel(); refresh = nil; projectionGeneration = UUID()
    }

    func selectRange(_ value: StatisticsRange) {
        guard selection.range != value else { return }; selection.range = value; snapshot = nil; refreshFailure = nil; reload()
    }

    func selectMeasure(_ value: StatisticsMeasure) { selection.measure = value; derive() }
    func selectList(_ value: StatisticsList) { selection.list = value; derive() }
    func selectRepository(_ id: String?) { selection.repository = id; derive() }
    func selectHarness(_ id: String?) { selection.harness = id; derive() }
    func selectRequestedModel(_ id: String?) { selection.requestedModel = id; derive() }
    func toggleRow(_ id: String) { if !selection.expanded.insert(id).inserted { selection.expanded.remove(id) }; derive() }
    func showNodes(for id: String) { selection.nodes = id; derive() }
    func showOverview() { selection.nodes = nil; derive() }
    func retry() { reload() }

    private func reload() {
        guard mounted else { return }
        task?.cancel(); projection?.cancel(); generation = UUID(); projectionGeneration = UUID()
        let token = generation, repository = useCase.repository
        let date = now(), cal = calendar(), range = selection.range
        if snapshot == nil {
            var loading = presentation; loading.state = .loading; loading.range = range; apply(loading)
        }
        task = Task { [weak self, worker] in
            let bounds = StatisticsProjection.bounds(range: range, now: date, calendar: cal)
            let result = await worker.read(repository: repository, since: bounds.since, before: bounds.before)
            guard let self, mounted, generation == token, !Task.isCancelled else { return }
            switch result {
            case .ready(var value):
                value.anchorDate = date; value.calendar = cal
                snapshot = value; refreshFailure = nil; derive()
            case .unsupported(let message): readFailed(message, unsupported: true)
            case .failed(let message): readFailed(message, unsupported: false)
            }
        }
    }

    private func derive() {
        guard mounted, let snapshot else { return }
        projection?.cancel()
        let token = UUID(); projectionGeneration = token
        let selected = selection, date = now(), cal = calendar()
        projection = Task { [weak self, worker] in
            var next = await worker.derive(snapshot: snapshot, selection: selected, now: date, calendar: cal)
            guard let self, mounted, projectionGeneration == token, !Task.isCancelled else { return }
            next.refreshFailure = refreshFailure
            apply(next)
        }
    }

    private func readFailed(_ message: String, unsupported: Bool) {
        if snapshot != nil {
            refreshFailure = "Showing the last complete snapshot. Refresh failed: " + message
            derive()
            return
        }
        var next = presentation
        next.state = unsupported ? .unsupported(message) : .error(message)
        apply(next)
    }

    private func apply(_ next: StatisticsPresentation) { if presentation != next { presentation = next } }
}
