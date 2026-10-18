//
//  ModelCombo.swift
//  MainWindowFeature
//

import PbUI
import SwiftUI

// MARK: - ModelChoiceModel

/// One suggestion in the Model combo. `id` is the value written into the field (empty for
/// "Default"); `title` is what the menu shows. Mapped from `ModelOption` in the VM.
struct ModelChoiceModel: Identifiable, Equatable {
    let id: String
    let title: String
}

// MARK: - ModelCombo

/// An editable combo box: a text field for any model id, with a trailing menu of suggestions. The
/// field is empty for "Default", so the placeholder says so.
struct ModelCombo: View {

    let text: String
    let choices: [ModelChoiceModel]
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("Default", text: Binding(get: { text }, set: onChange))
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
                    .font(.pb(.caption, weight: .semibold))
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
        .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.composerFill))
        .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
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
