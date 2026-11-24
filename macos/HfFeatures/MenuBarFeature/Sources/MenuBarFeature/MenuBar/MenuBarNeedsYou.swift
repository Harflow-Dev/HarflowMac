import Combine
import Foundation
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - MenuBarNeedsYouSection

/// The popover's Needs you section. Hidden while loading; equality covers every rendered field.
struct MenuBarNeedsYouSection: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let kindLabel: String
        let title: String
        /// "Ended · Original caller" once the caller ended, else who started it (design `menuRow`).
        let subtitle: String
        var item: NeedsYouItem?
        var canDecide = false
        var submitting = false
        var resultLines: [String] = []
        var showsRefresh = false
    }

    static let rowLimit = 3
    static let unsupportedLine = "This Harflow runtime version cannot report workflow questions here."

    let count: Int
    let isLowerBound: Bool
    var rows: [Row]
    /// The engine reports no workflow interactions, so only task approvals can appear.
    let olderEngine: Bool

    var label: String { count > 0 ? "Needs you · \(count)" : "Needs you" }
    var showAllTitle: String { "Show all \(count)" }
    var showsShowAll: Bool { count > rows.count }

    /// Nil while loading, so the section stays out of the popover until the first complete pass.
    init?(_ snapshot: NeedsYouSnapshot) {
        if snapshot.phase == .loading, snapshot.items.isEmpty { return nil }
        self.count = snapshot.items.count
        self.isLowerBound = snapshot.isLowerBound
        self.olderEngine = snapshot.workflowInputsUnsupported
        self.rows = snapshot.items.prefix(Self.rowLimit).map {
            var row = Row(id: $0.id, kindLabel: Self.kindLabel($0.kind), title: $0.runTitle,
                subtitle: $0.ownership.callerEnded ? "Ended · \($0.startedBy)" : $0.startedBy)
            row.item = $0
            row.canDecide = $0.kind == .approval && $0.approvalCanRespond && $0.approvalContext != nil
            return row
        }
    }

    init(count: Int, isLowerBound: Bool = false, rows: [Row], olderEngine: Bool = false) {
        self.count = count
        self.isLowerBound = isLowerBound
        self.rows = rows
        self.olderEngine = olderEngine
    }

    private static func kindLabel(_ kind: NeedsYouItem.Kind) -> String {
        switch kind {
        case .approval: "Approval"
        case .question: "Question"
        case .recovery: "Recovery"
        }
    }
}

// MARK: - MenuBarNeedsYouUseCase

/// The menu bar's read side of Needs you, kept apart from `MenuBarUseCase` like the count-availability seam.
@MainActor
protocol MenuBarNeedsYouUseCase {
    var needsYouSnapshot: NeedsYouSnapshot { get }
    func needsYouSnapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never>
    func respondToApproval(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome
    func isApprovalContextCurrent(_ item: NeedsYouItem) -> Bool
    func retainedApprovalResult(_ item: NeedsYouItem) -> ApprovalResponseOutcome?
    func canReviewApprovalAgain(_ item: NeedsYouItem) async -> Bool
    func refreshNeedsYou()
}

extension MenuBarNeedsYouUseCase {
    func respondToApproval(_: NeedsYouItem, decision _: String) async -> NeedsYouAnswerOutcome { .failed("Approval responses are unavailable.") }
    func isApprovalContextCurrent(_: NeedsYouItem) -> Bool { false }
    func retainedApprovalResult(_: NeedsYouItem) -> ApprovalResponseOutcome? { nil }
    func canReviewApprovalAgain(_: NeedsYouItem) async -> Bool { false }
    func refreshNeedsYou() {}
}

// MARK: - MenuBarNeedsYouSectionView

struct MenuBarNeedsYouSectionView: View {
    let section: MenuBarNeedsYouSection
    let open: (String) -> Void
    let showAll: () -> Void
    var decide: (MenuBarNeedsYouSection.Row, String) -> Void = { _, _ in }
    var refresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            MenuBarSectionLabel(text: section.label)
            if section.rows.isEmpty {
                Text("Nothing needs you").font(.hf(.secondary)).foregroundStyle(Color.primaryText)
            }
            ForEach(section.rows) { row in
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    HStack {
                        Text(row.kindLabel).font(.hf(.caption, weight: .semibold)).foregroundStyle(Color.warningFG)
                        Spacer()
                        Button("Open") { open(row.id) }.buttonStyle(.link).font(.hf(.caption))
                    }
                    Text(row.title).font(.hf(.body, weight: .semibold)).lineLimit(1)
                    if let item = row.item, item.kind == .approval {
                        Text(item.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let request = item.approval {
                            Text(JSONValue.object(request.raw["action"]?.objectValue ?? [:]).rendered())
                                .font(.system(.caption, design: .monospaced))
.textSelection(.enabled)
                            Text("Working directory: " + request.text("cwd")).font(.hf(.caption)).textSelection(.enabled)
                        }
                        ForEach(row.resultLines, id: \.self) { Text($0).font(.hf(.caption)).textSelection(.enabled) }
                        if row.canDecide {
                            HStack {
                                Button(row.submitting ? "Submitting…" : "Approve once") { decide(row, "approve") }.buttonStyle(.borderedProminent)
                                Button("Reject", role: .destructive) { decide(row, "reject") }
                            }.disabled(row.submitting)
                        }
                        if row.showsRefresh { Button("Refresh", action: refresh).buttonStyle(.bordered) }
                    } else {
                        Text(row.subtitle).font(.hf(.caption))
                        Button("Answer") { open(row.id) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(HfRadius.Metrics.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
                .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.hairline))
            }
            if section.showsShowAll {
                Button(section.showAllTitle, action: showAll).buttonStyle(.link).font(.hf(.secondary))
            }
            if section.olderEngine {
                Text(MenuBarNeedsYouSection.unsupportedLine)
                    .font(.hf(.caption))
.foregroundStyle(Color.primaryText)
            }
        }
    }
}

// MARK: - MenuBarVM

extension MenuBarVM {
    func didSelectNeedsYou(_ itemID: String) {
        routing.select(.needsYou(itemID: itemID))
        routing.openWindow()
    }

    func didTapShowAllNeedsYou() {
        routing.select(.needsYou(itemID: nil))
        routing.openWindow()
    }

    /// Idempotent; released in `didDisappear()` so a reopened popover subscribes again.
    func subscribeToNeedsYou() {
        guard needsYouSubscription == nil, let source = needsYouSource else { return }
        updateNeedsYou(source.needsYouSnapshot)
        needsYouSubscription = source.needsYouSnapshotPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] snapshot in self?.updateNeedsYou(snapshot) }
    }

    func updateNeedsYou(_ snapshot: NeedsYouSnapshot) {
        guard var section = MenuBarNeedsYouSection(snapshot) else { needsYou = nil; return }
        section.rows = section.rows.map { row in
            var result = row
            guard let item = row.item else { return result }
            result.canDecide = result.canDecide && needsYouSource?.isApprovalContextCurrent(item) == true
            if approvalSubmitting.contains(row.id) { result.submitting = true }
            if let outcome = needsYouSource?.retainedApprovalResult(item) ?? approvalResults[row.id].flatMap({ $0.item == item ? $0.outcome : nil }) {
                result.canDecide = false
                result.resultLines = MenuBarApprovalResult.lines(outcome)
                if case .refused(let error, _) = outcome {
                    result.showsRefresh = error.callerApprovalWinner == nil
                        && error.callerApprovalResponseReason != .expired && error.callerApprovalResponseReason != .settled
                }
            }
            return result
        }
        if needsYou != section { needsYou = section }
    }

    func didDecideApproval(_ row: MenuBarNeedsYouSection.Row, decision: String) {
        guard ["approve", "reject"].contains(decision), row.canDecide, !row.submitting,
              needsYou?.rows.first(where: { $0.id == row.id }) == row,
              let item = row.item, let source = needsYouSource, !approvalSubmitting.contains(row.id) else { return }
        approvalSubmitting.insert(row.id)
        updateNeedsYou(source.needsYouSnapshot)
        Task { [weak self] in
            let outcome = await source.respondToApproval(item, decision: decision)
            guard let self else { return }
            approvalSubmitting.remove(row.id)
            switch outcome {
            case .approvalOutcome(let facts):
                approvalResults[row.id] = facts == .busy ? nil : MenuBarApprovalHeldResult(item: item, outcome: facts)
            case .accepted: break
            default: break
            }
            updateNeedsYou(source.needsYouSnapshot)
        }
    }

    func didRefreshApprovals() {
        guard let source = needsYouSource else { return }
        source.refreshNeedsYou()
        for (id, held) in approvalResults {
            guard case .refused = held.outcome else { continue }
            Task { [weak self] in
                guard await source.canReviewApprovalAgain(held.item), let self,
                      approvalResults[id]?.item == held.item else { return }
                approvalResults[id] = nil
                updateNeedsYou(source.needsYouSnapshot)
            }
        }
    }

}

// MARK: - MenuBarApprovalResult

enum MenuBarApprovalResult {
    static func lines(_ outcome: ApprovalResponseOutcome) -> [String] {
        switch outcome {
        case .uncertain: [ApprovalResponseOutcome.uncertainMessage]
        case .busy: ["An approval response is already in progress."]
        case .recorded(let request): ["Recorded decision: " + request.text("decision")]
        case .refused(let error, _):
            if let winner = error.callerApprovalWinner {
                [winner.answeredBy == .caller ? "Already answered by the caller" : "Answered in Harflow",
                 Date(timeIntervalSince1970: winner.answeredAt).formatted(date: .abbreviated, time: .shortened),
                 "Recorded decision: " + winner.decision]
            } else if error.callerApprovalResponseReason == .notCurrent {
                ["The request changed or is no longer current. This response did not change it. Refresh to review the current action."]
            } else if error.callerApprovalResponseReason == .settled {
                ["This request has already settled. This response did not change it."]
            } else { [error.message] }
        }
    }
}

struct MenuBarApprovalHeldResult {
    let item: NeedsYouItem
    let outcome: ApprovalResponseOutcome
}
