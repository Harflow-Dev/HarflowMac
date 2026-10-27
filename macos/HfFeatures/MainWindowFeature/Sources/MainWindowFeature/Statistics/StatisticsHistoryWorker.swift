import Foundation
import HfRepository
import MonitorCore

// MARK: - StatisticsSnapshot

struct StatisticsSnapshot: Equatable, Sendable {
    var facts: [StatisticsFact]
    var page: StatisticsPage
    var anchorDate: Date?
    var calendar: Calendar?
}

enum StatisticsHistoryResult: Sendable {
    case ready(StatisticsSnapshot)
    case unsupported(String)
    case failed(String)
}

// MARK: - StatisticsHistoryWorker

/// Owns bounded page walking outside the main actor. No partial totals escape this boundary.
actor StatisticsHistoryWorker {
    static let maxPages = 200
    static let maxFacts = 20000
    private let now: @Sendable () -> ContinuousClock.Instant
    private let budget: Duration

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, budget: Duration = .seconds(30)) {
        self.now = now; self.budget = budget
    }

    private enum WalkResult {
        case complete(StatisticsHistoryResult), expired
    }

    private struct WalkState {
        var cursor: String?
        var generation: String?
        var snapshotID: String?
        var facts: [StatisticsFact] = []
        var identities: Set<String> = []
        var cursors: Set<String> = []
        var preparing = 0
        var pages = 0

        mutating func append(_ page: StatisticsPage) -> String? {
            for fact in page.items {
                guard identities.insert("\(fact.kind):\(fact.id)").inserted else { return "History returned duplicate facts. Retry." }
                facts.append(fact)
            }
            guard facts.count <= StatisticsHistoryWorker.maxFacts else { return "History exceeds the supported page limit. No totals are shown." }
            pages += 1
            if page.hasMore {
                guard let next = page.nextCursor, cursors.insert(next).inserted else { return "History pagination did not advance. Retry." }
                cursor = next
            }
            return nil
        }
    }

    func read(repository: any StatisticsRepository, since: String, before: String) async -> StatisticsHistoryResult {
        let deadline = now() + budget
        for _ in 0 ... 2 {
            switch await walk(repository: repository, since: since, before: before, deadline: deadline) {
            case .complete(let result): return result
            case .expired: continue
            }
        }
        return .failed("History changed repeatedly. Retry when it settles.")
    }

    private func walk(repository: any StatisticsRepository, since: String, before: String, deadline: ContinuousClock.Instant) async -> WalkResult {
        var walk = WalkState()
        while walk.pages < Self.maxPages, !Task.isCancelled, now() < deadline {
            let result = await repository.page(since: since, before: before, cursor: walk.cursor)
            guard !Task.isCancelled else { return .complete(.failed("Statistics cancelled")) }
            guard now() < deadline else { return .complete(.failed("History read exceeded its time budget. No totals are shown.")) }
            switch result {
            case .failure(let error):
                if case .unsupportedCommand = error { return .complete(.unsupported(error.message)) }
                if error.refusalCode == "snapshot_expired" { return .expired }
                return .complete(.failed(error.message))
            case .success(let page):
                if page.state == "preparing" {
                    guard await prepare(&walk) else { return .complete(.failed("History preparation is incomplete. Retry to continue.")) }
                    continue
                }
                if let completion = accept(page, walk: &walk, deadline: deadline) { return completion }
            }
        }
        return .complete(.failed("History exceeds the supported page limit or was cancelled. No totals are shown."))
    }

    private func accept(_ page: StatisticsPage, walk: inout WalkState, deadline: ContinuousClock.Instant) -> WalkResult? {
        if let failure = readinessFailure(page) { return .complete(.failed(failure)) }
        if snapshotChanged(page, walk: walk) { return .expired }
        walk.generation = page.generation; walk.snapshotID = page.snapshotID
        if let failure = walk.append(page) { return .complete(.failed(failure)) }
        if !page.hasMore {
            guard !Task.isCancelled, now() < deadline else {
                return .complete(.failed("History read exceeded its time budget or was cancelled. No totals are shown."))
            }
            return .complete(.ready(.init(facts: walk.facts, page: page)))
        }
        return nil
    }

    private func prepare(_ walk: inout WalkState) async -> Bool {
        guard walk.cursor == nil, walk.facts.isEmpty, walk.preparing < 30 else { return false }
        walk.preparing += 1
        do { try await Task.sleep(for: .milliseconds(250)); return true } catch { return false }
    }

    private func snapshotChanged(_ page: StatisticsPage, walk: WalkState) -> Bool {
        (walk.generation != nil && walk.generation != page.generation) || (walk.snapshotID != nil && walk.snapshotID != page.snapshotID)
    }

    private func readinessFailure(_ page: StatisticsPage) -> String? {
        guard page.state == "ready", page.historyComplete, page.ownershipComplete else {
            return page.diagnostics.isEmpty ? "History is incomplete or unavailable. No totals are shown." : page.diagnostics.joined(separator: " · ")
        }
        return nil
    }

    func derive(snapshot: StatisticsSnapshot, selection: StatisticsSelection, now: Date, calendar: Calendar) -> StatisticsPresentation {
        StatisticsProjection.derive(snapshot: snapshot, selection: selection, now: now, calendar: calendar)
    }
}
