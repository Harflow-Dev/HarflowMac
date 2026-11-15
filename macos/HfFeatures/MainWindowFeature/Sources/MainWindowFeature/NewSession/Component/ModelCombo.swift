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
/// selectable); the combo ignores them and the workflow editor reads them. `isDefault` marks the row the
/// harness reports as its default; the combo tags it "default".
struct ModelChoiceModel: Identifiable, Equatable {
    let id: String
    let title: String
    var effortLevels: [String]?
    var isDefault = false
}

// MARK: - ModelCombo

/// An editable combo box: a text field for any model id, with a trailing menu of suggestions. The
/// field is empty for "Default", so the placeholder says so.
struct ModelCombo: View {

    let text: String
    let choices: [ModelChoiceModel]
    /// The note under the field, read as the field's accessibility hint; `nil` for none.
    var hint: String?
    /// Changing this value moves keyboard focus into the field.
    var focusRequest = 0
    let onChange: @MainActor (String) -> Void

    @FocusState private var fieldFocused: Bool

    init(
        text: String, choices: [ModelChoiceModel], hint: String? = nil, focusRequest: Int = 0,
        onChange: @escaping @MainActor (String) -> Void
    ) {
        self.text = text
        self.choices = choices
        self.hint = hint
        self.focusRequest = focusRequest
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Default", text: Binding(get: { text }, set: { onChange($0) }))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .accessibilityLabel("Model")
                .accessibilityHint(hint ?? "")
                .onChange(of: focusRequest) { fieldFocused = true }
            Menu {
                ForEach(choices) { choice in
                    Button {
                        onChange(choice.id)
                    } label: {
                        choiceLabel(choice)
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

extension ModelCombo {

    /// One suggestion row. A native menu item cannot right-align a pill, so a default row carries a trailing
    /// secondary "default" in the same item (a native menu item reads as its plain title, "{title} default").
    @ViewBuilder
    private func choiceLabel(_ choice: ModelChoiceModel) -> some View {
        let name = Text(choice.title)
        let title = choice.isDefault ? name + Text(" default").foregroundStyle(Color.secondaryText) : name
        if choice.id == text {
            Label { title } icon: { Image(systemName: "checkmark") }
        } else {
            title
        }
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
