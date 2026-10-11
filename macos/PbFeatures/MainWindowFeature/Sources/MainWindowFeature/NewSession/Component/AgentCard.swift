//
//  AgentCard.swift
//  MainWindowFeature
//

import PbUI
import SwiftUI

// MARK: - AgentCardModel

/// One selectable agent on the New Session sheet. Mapped from `BackendTab` in the VM.
struct AgentCardModel: Identifiable, Equatable {
    let id: String
    let name: String
    /// One line on what the agent is good for; `nil` for an unrecognised backend.
    let helpText: String?
    let isSelected: Bool
    /// Positively confirmed missing from PATH: the card stays visible but cannot be chosen.
    let isNotInstalled: Bool

    /// "<name>, <help text>", or just the name when there is no help text.
    var accessibilityText: String {
        [name, helpText].compactMap(\.self).joined(separator: ", ")
    }
}

// MARK: - AgentCard

/// A selectable card: coloured backend dot, name, and one line of help text.
struct AgentCard: View {

    let model: AgentCardModel
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    BackendDot(backend: model.id)
                    Text(model.name).font(.pb(.body, weight: .semibold))
                    Spacer(minLength: PbRadius.Metrics.zero)
                    if model.isNotInstalled {
                        Text("Not installed").font(.pb(.caption, weight: .medium)).foregroundStyle(Color.warningFG)
                    } else if model.isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentLink)
                    }
                }
                // Always two lines' worth of room, so every card in the grid is the same height
                // however long (or absent) its help text is.
                Text(model.helpText ?? " ")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityHidden(model.helpText == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PbRadius.Metrics.spacing12)
            .padding(.vertical, PbRadius.Metrics.spacing14)
            // The selected card is a running-tint fill with a named accent border — never an
            // opacity-derived tint.
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(model.isSelected ? Color.runningBG : Color.cardFill))
            .overlay {
                RoundedRectangle(cornerRadius: PbRadius.card)
                    .stroke(model.isSelected ? Color.accentLink : Color.cardBorder,
                            lineWidth: model.isSelected ? PbRadius.Metrics.newSessionCardSelectedBorderWidth : PbRadius.Metrics.hairlineStroke)
            }
            .contentShape(RoundedRectangle(cornerRadius: PbRadius.card))
        }
        .buttonStyle(.plain)
        .disabled(model.isNotInstalled)
        .opacity(model.isNotInstalled ? 0.55 : 1)
        .accessibilityLabel(model.accessibilityText)
        .accessibilityValue(model.isNotInstalled ? "Not installed" : "")
        .accessibilityAddTraits(model.isSelected ? .isSelected : [])
    }
}

// MARK: - AgentGrid

/// The agent cards in an adaptive row: one row of up to five at the usual 760-wide sheet, wrapping
/// to the actual catalog count and available width beyond that. Arrow keys move focus between the
/// enabled cards along the grid's ACTUAL visual column count; Space or Return on a focused card
/// selects it — the same keyboard actions and selection semantics as before, no new shortcut.
struct AgentGrid: View {

    /// The fallback column count for callers that cannot see the geometry (previews, tests); the
    /// live grid always passes its measured count.
    static let fallbackColumnCount = 2

    let cards: [AgentCardModel]
    let onSelect: (String) -> Void

    @FocusState private var focusedID: String?
    @State private var columnCount = AgentGrid.fallbackColumnCount
    @State private var availableWidth: CGFloat = PbRadius.Metrics.zero

    /// The visual column count for `availableWidth`: as many cards as fit at the minimum card
    /// width, capped by the catalog's own count — five at the default 760-wide sheet.
    static func resolvedColumnCount(cardCount: Int, availableWidth: CGFloat) -> Int {
        guard cardCount > 0, availableWidth > 0 else { return 1 }
        let spacing = PbRadius.Metrics.spacing12
        let columns = Int((availableWidth + spacing) / (PbRadius.Metrics.newSessionAgentCardMinimumWidth + spacing))
        return max(1, min(cardCount, columns))
    }

    /// The index the focus should move to for `direction` from `index`, skipping disabled cards;
    /// `nil` when nothing lies that way.
    static func nextIndex(from index: Int, direction: MoveCommandDirection, enabled: [Bool], columns: Int = fallbackColumnCount) -> Int? {
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        @unknown default: return nil
        }
        var candidate = index + step
        while enabled.indices.contains(candidate) {
            if enabled[candidate] { return candidate }
            if abs(step) == columns { break }
            candidate += step
        }
        return nil
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PbRadius.Metrics.spacing12), count: columnCount),
                  spacing: PbRadius.Metrics.spacing12) {
            ForEach(cards) { card in
                AgentCard(model: card) { onSelect(card.id) }
                    .focusable(!card.isNotInstalled)
                    .focused($focusedID, equals: card.id)
                    .onKeyPress(.return) {
                        guard !card.isNotInstalled else { return .ignored }
                        onSelect(card.id)
                        return .handled
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
            if availableWidth != width { availableWidth = width }
            updateColumnCount()
        }
        .onChange(of: cards.count) { _, _ in updateColumnCount() }
        .onMoveCommand { direction in
            guard let current = cards.firstIndex(where: { $0.id == focusedID }),
                  let next = Self.nextIndex(from: current, direction: direction,
                                            enabled: cards.map { !$0.isNotInstalled }, columns: columnCount) else { return }
            focusedID = cards[next].id
        }
    }

    /// The catalog may load without changing the already measured grid width.
    private func updateColumnCount() {
        let next = Self.resolvedColumnCount(cardCount: cards.count, availableWidth: availableWidth)
        if next != columnCount { columnCount = next }
    }
}

#if DEBUG
private let previewCards = [
    AgentCardModel(id: "claude", name: "Claude", helpText: BackendStyle.helpText("claude"), isSelected: true, isNotInstalled: false),
    AgentCardModel(id: "codex", name: "Codex", helpText: BackendStyle.helpText("codex"), isSelected: false, isNotInstalled: false),
    AgentCardModel(id: "vibe", name: "Vibe", helpText: BackendStyle.helpText("vibe"), isSelected: false, isNotInstalled: false),
    AgentCardModel(id: "opencode", name: "Opencode", helpText: BackendStyle.helpText("opencode"), isSelected: false, isNotInstalled: true),
    AgentCardModel(id: "mystery", name: "Mystery", helpText: nil, isSelected: false, isNotInstalled: false)
]

#Preview("AgentGrid wide, one row of 5 - light") {
    AgentGrid(cards: previewCards, onSelect: { _ in })
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.newSessionSheetWidth - 2 * PbRadius.Metrics.spacing28)
        .background(Color.windowBG)
        .preferredColorScheme(.light)
}

#Preview("AgentGrid wide, one row of 5 - dark") {
    AgentGrid(cards: previewCards, onSelect: { _ in })
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.newSessionSheetWidth - 2 * PbRadius.Metrics.spacing28)
        .background(Color.windowBG)
        .preferredColorScheme(.dark)
}

#Preview("AgentGrid narrow, two columns - light") {
    AgentGrid(cards: previewCards, onSelect: { _ in })
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.newSessionAgentCardMinimumWidth * 2)
        .background(Color.windowBG)
        .preferredColorScheme(.light)
}

#Preview("AgentGrid narrow, two columns - dark") {
    AgentGrid(cards: previewCards, onSelect: { _ in })
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.newSessionAgentCardMinimumWidth * 2)
        .background(Color.windowBG)
        .preferredColorScheme(.dark)
}
#endif
