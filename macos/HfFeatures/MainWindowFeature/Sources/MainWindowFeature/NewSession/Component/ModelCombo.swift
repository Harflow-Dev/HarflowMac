//
//  ModelCombo.swift
//  MainWindowFeature
//

import HfUI
import SwiftUI

// MARK: - ModelChoiceModel

/// One suggestion in the Model combo. `id` is the value written into the field (empty for
/// "Default"); `title` is what the menu shows. Mapped from `ModelOption` in the VM. `effortLevels` are
/// the engine's selectable effort levels for that model (`nil`: it says nothing; empty: none is
/// selectable); the combo ignores them and the workflow editor reads them.
struct ModelChoiceModel: Identifiable, Equatable {
    let id: String
    let title: String
    var effortLevels: [String]?
}

// MARK: - ModelCombo

/// An editable combo box: a text field for any model id, with a trailing menu of suggestions. The
/// field is empty for "Default", so the placeholder says so.
struct ModelCombo: View {

    let text: String
    let choices: [ModelChoiceModel]
    let onChange: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("Default", text: Binding(get: { text }, set: { onChange($0) }))
                .textFieldStyle(.plain)
                .accessibilityLabel("Model")
            Menu {
                ForEach(choices) { choice in
                    Button {
                        onChange(choice.id)
                    } label: {
                        if choice.id == text {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hf(.caption, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(choices.count < 2)
            .accessibilityLabel("Suggested models")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.composerFill))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
    }
}

#if DEBUG
private let previewChoices = [
    ModelChoiceModel(id: "", title: "Default"),
    ModelChoiceModel(id: "opus", title: "Opus"),
    ModelChoiceModel(id: "sonnet", title: "Sonnet")
]

private struct ModelComboPreview: View {
    @State private var text: String

    init(text: String) { _text = State(initialValue: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelCombo(text: text, choices: previewChoices) { text = $0 }
            ModelCombo(text: "", choices: [ModelChoiceModel(id: "", title: "Default")]) { _ in }
        }
        .padding(20)
        .frame(width: 360)
        .background(Color.windowBG)
    }
}

#Preview("ModelCombo - light") { ModelComboPreview(text: "opus").preferredColorScheme(.light) }
#Preview("ModelCombo - dark") { ModelComboPreview(text: "").preferredColorScheme(.dark) }
#endif
