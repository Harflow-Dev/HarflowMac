//
//  AccessOptionRow.swift
//  MainWindowFeature
//

import PbUI
import SwiftUI

// MARK: - AccessOptionModel

/// One row of the "What can it change?" radio group. Mapped from a `freedom` value in the VM.
struct AccessOptionModel: Identifiable, Equatable {
    /// The `freedom` value this row selects.
    let id: String
    let title: String
    let detail: String
    let isSelected: Bool
    /// Shows a warning icon beside the title.
    let isWarning: Bool
}

// MARK: - AccessOptionRow

/// A radio row: circle, title and one line of explanation. A button with the selected trait, so it
/// is reachable by keyboard and VoiceOver.
struct AccessOptionRow: View {

    let model: AccessOptionModel
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: PbRadius.Metrics.spacing12) {
                radio
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                    HStack(spacing: PbRadius.Metrics.spacing6) {
                        Text(model.title).font(.pb(.body, weight: .semibold))
                        if model.isWarning {
                            Image(systemName: "exclamationmark.triangle").font(.pb(.secondary)).foregroundStyle(Color.warningFG)
                        }
                    }
                    Text(model.detail)
                        .font(.pb(.secondary))
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PbRadius.Metrics.zero)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PbRadius.Metrics.spacing12)
            .padding(.vertical, PbRadius.Metrics.spacing14)
            // The selected card is a running-tint fill with a named accent border — never an
            // opacity-derived tint (the same treatment as the selected agent card).
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(model.isSelected ? Color.runningBG : Color.cardFill))
            .overlay {
                RoundedRectangle(cornerRadius: PbRadius.card)
                    .stroke(model.isSelected ? Color.accentLink : Color.cardBorder,
                            lineWidth: model.isSelected ? PbRadius.Metrics.newSessionCardSelectedBorderWidth : PbRadius.Metrics.hairlineStroke)
            }
            .contentShape(RoundedRectangle(cornerRadius: PbRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.title), \(model.detail)")
        .accessibilityAddTraits(model.isSelected ? .isSelected : [])
    }

    private var radio: some View {
        Circle()
            .strokeBorder(model.isSelected ? Color.accentLink : Color.accessRadioBorder,
                          lineWidth: model.isSelected ? PbRadius.Metrics.accessRadioSelectedStroke : PbRadius.Metrics.accessRadioUnselectedStroke)
            .frame(width: PbRadius.Metrics.spacing16, height: PbRadius.Metrics.spacing16)
            .padding(.top, PbRadius.Metrics.hairlineStroke)
            .accessibilityHidden(true)
    }
}

#if DEBUG
private let previewOptions = [
    AccessOptionModel(
        id: "read_only", title: "Read-only",
        detail: "Requests read-only repo review.",
        isSelected: true, isWarning: false
    ),
    AccessOptionModel(
        id: "write_in_repo", title: "Can edit this repo",
        detail: "Requests repo edits, no publishing.",
        isSelected: false, isWarning: false
    ),
    AccessOptionModel(
        id: "publish", title: "Can publish",
        detail: "Requests edits and publish attempts.",
        isSelected: false, isWarning: false
    ),
    AccessOptionModel(
        id: "unrestricted", title: "Full access",
        detail: "Requests broad access; use sparingly.",
        isSelected: false, isWarning: true
    )
]

private struct AccessOptionRowPreview: View {
    var body: some View {
        // The default 760-wide sheet's 2×2 layout.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: PbRadius.Metrics.newSessionAccessCardMinimumWidth),
                                     spacing: PbRadius.Metrics.spacing12)],
                  spacing: PbRadius.Metrics.spacing12) {
            ForEach(previewOptions) { AccessOptionRow(model: $0, onSelect: {}) }
        }
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.newSessionSheetWidth - 2 * PbRadius.Metrics.spacing28)
        .background(Color.windowBG)
    }
}

#Preview("AccessOptionRow - light") { AccessOptionRowPreview().preferredColorScheme(.light) }
#Preview("AccessOptionRow - dark") { AccessOptionRowPreview().preferredColorScheme(.dark) }

/// The narrower overflow fallback: one column, descriptions wrap without truncation.
private struct AccessOptionRowNarrowPreview: View {
    var body: some View {
        VStack(spacing: PbRadius.Metrics.spacing12) {
            ForEach(previewOptions) { AccessOptionRow(model: $0, onSelect: {}) }
        }
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.newSessionAccessCardMinimumWidth)
        .background(Color.windowBG)
    }
}

#Preview("AccessOptionRow narrow - light") { AccessOptionRowNarrowPreview().preferredColorScheme(.light) }
#Preview("AccessOptionRow narrow - dark") { AccessOptionRowNarrowPreview().preferredColorScheme(.dark) }
#endif
