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
            HStack(alignment: .top, spacing: 12) {
                radio
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(model.isSelected ? Color.accentLink.opacity(0.1) : Color.cardFill))
            .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(model.isSelected ? Color.accentLink : Color.cardBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: PbRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.title), \(model.detail)")
        .accessibilityAddTraits(model.isSelected ? .isSelected : [])
    }

    private var radio: some View {
        Circle()
            .strokeBorder(model.isSelected ? Color.accentLink : Color.secondaryText.opacity(0.6), lineWidth: model.isSelected ? 5 : 1.5)
            .frame(width: 16, height: 16)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }
}

#if DEBUG
private let previewOptions = [
    AccessOptionModel(
        id: "read_only", title: "Read-only",
        detail: "Reads the code and answers. Doesn't change any files. Good for questions and reviews.",
        isSelected: true, isWarning: false
    ),
    AccessOptionModel(
        id: "write_in_repo", title: "Can edit this repo",
        detail: "Edits files in the repo. Commits and pushes are blocked, so you review before anything leaves.",
        isSelected: false, isWarning: false
    ),
    AccessOptionModel(
        id: "unrestricted", title: "Full access",
        detail: "No limits from polybridge. The agent can touch anything your user account can. Use sparingly.",
        isSelected: false, isWarning: true
    )
]

private struct AccessOptionRowPreview: View {
    var body: some View {
        VStack(spacing: 8) {
            ForEach(previewOptions) { AccessOptionRow(model: $0, onSelect: {}) }
        }
        .padding(20)
.frame(width: 600)
.background(Color.windowBG)
    }
}

#Preview("AccessOptionRow - light") { AccessOptionRowPreview().preferredColorScheme(.light) }
#Preview("AccessOptionRow - dark") { AccessOptionRowPreview().preferredColorScheme(.dark) }
#endif
