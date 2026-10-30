import Combine
import Foundation
import HfRepository
import HfUI
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
    }

    static let rowLimit = 3

    let count: Int
    let isLowerBound: Bool
    let rows: [Row]
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
            Row(id: $0.id, kindLabel: Self.kindLabel($0.kind), title: $0.runTitle,
                subtitle: $0.ownership.callerEnded ? "Ended · \($0.startedBy)" : $0.startedBy)
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
}

// MARK: - MenuBarNeedsYouSectionView

struct MenuBarNeedsYouSectionView: View {
    let section: MenuBarNeedsYouSection
    let open: (String) -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            MenuBarSectionLabel(text: section.label)
            if section.rows.isEmpty {
                Text("Nothing needs you").font(.hf(.secondary)).foregroundStyle(Color.primaryText)
            }
            ForEach(section.rows) { row in
                MenuBarRecentRowButton { open(row.id) } content: {
                    HStack(spacing: HfRadius.Metrics.spacing8) {
                        Text(row.kindLabel)
                            .font(.hf(.caption, weight: .semibold))
                            .padding(.horizontal, HfRadius.Metrics.spacing6)
                            .background(Color.warningBG, in: Capsule())
                            .foregroundStyle(Color.warningFG)
                        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                            Text(row.title).font(.hf(.body)).lineLimit(1)
                            Text(row.subtitle).font(.hf(.caption)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.primaryText)
                    .contentShape(Rectangle())
                }
            }
            if section.showsShowAll {
                Button(section.showAllTitle, action: showAll).buttonStyle(.link).font(.hf(.secondary))
            }
            if section.olderEngine {
                Text("This engine version cannot report workflow questions here.")
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
        needsYou = MenuBarNeedsYouSection(source.needsYouSnapshot)
        needsYouSubscription = source.needsYouSnapshotPublisher()
            .map { MenuBarNeedsYouSection($0) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] section in
                guard let self, needsYou != section else { return }
                needsYou = section
            }
    }
}
