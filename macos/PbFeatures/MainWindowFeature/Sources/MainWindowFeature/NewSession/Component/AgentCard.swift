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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    BackendDot(backend: model.id)
                    Text(model.name).font(.pb(.body, weight: .semibold))
                    Spacer(minLength: 0)
                    if model.isNotInstalled {
                        Text("Not installed").font(.pb(.caption, weight: .medium)).foregroundStyle(Color.warningFG)
                    } else if model.isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentLink)
                    }
                }
                if let helpText = model.helpText {
                    Text(helpText)
                        .font(.pb(.secondary))
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(model.isSelected ? Color.accentLink.opacity(0.1) : Color.cardFill))
            .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(model.isSelected ? Color.accentLink : Color.cardBorder, lineWidth: 1))
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

/// The two-column grid of agent cards. Arrow keys move focus between the enabled cards; Space or
/// Return on a focused card selects it.
struct AgentGrid: View {

    static let columnCount = 2

    let cards: [AgentCardModel]
    let onSelect: (String) -> Void

    @FocusState private var focusedID: String?

    /// The index the focus should move to for `direction` from `index`, skipping disabled cards;
    /// `nil` when nothing lies that way.
    static func nextIndex(from index: Int, direction: MoveCommandDirection, enabled: [Bool], columns: Int = columnCount) -> Int? {
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.columnCount), spacing: 8) {
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
        .onMoveCommand { direction in
            guard let current = cards.firstIndex(where: { $0.id == focusedID }),
                  let next = Self.nextIndex(from: current, direction: direction, enabled: cards.map { !$0.isNotInstalled }) else { return }
            focusedID = cards[next].id
        }
    }
}

#if DEBUG
private let previewCards = [
    AgentCardModel(id: "claude", name: "Claude", helpText: BackendStyle.helpText("claude"), isSelected: true, isNotInstalled: false),
    AgentCardModel(id: "codex", name: "Codex", helpText: BackendStyle.helpText("codex"), isSelected: false, isNotInstalled: false),
    AgentCardModel(id: "vibe", name: "Vibe", helpText: BackendStyle.helpText("vibe"), isSelected: false, isNotInstalled: false),
    AgentCardModel(id: "opencode", name: "opencode", helpText: BackendStyle.helpText("opencode"), isSelected: false, isNotInstalled: true),
    AgentCardModel(id: "mystery", name: "Mystery", helpText: nil, isSelected: false, isNotInstalled: false)
]

#Preview("AgentGrid - light") {
    AgentGrid(cards: previewCards, onSelect: { _ in })
        .padding(20)
.frame(width: 600)
.background(Color.windowBG)
.preferredColorScheme(.light)
}

#Preview("AgentGrid - dark") {
    AgentGrid(cards: previewCards, onSelect: { _ in })
        .padding(20)
.frame(width: 600)
.background(Color.windowBG)
.preferredColorScheme(.dark)
}
#endif
