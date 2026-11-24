//
//  MenuBarQuestionCard.swift
//  MenuBarFeature
//

import HfUI
import SwiftUI

// MARK: - MenuBarQuestionCard

/// The popover's inline question card (`menu-bar/question-*`). It only draws `MenuBarQuestionState`; the VM owns the draft
/// and the phase. A settled card has no field, a failed one keeps the field and shows the refusal code on a detail line.
struct MenuBarQuestionCard: View {
    let title: String
    let text: String
    let state: MenuBarQuestionState
    let edit: (String) -> Void
    let submit: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            HStack(spacing: HfRadius.Metrics.spacing4) {
                StatusGlyphView(.hand, size: HfRadius.Metrics.statusBadgeGlyphFrame).accessibilityHidden(true)
                Text("Question").font(.hf(.caption, weight: .semibold))
            }
            .foregroundStyle(Color.warningFG)
            Text("\(title) asks: \(text)")
                .font(.hf(.body))
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(HfRadius.Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-question-card")
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .settled(let title, let lines, let action):
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                if let title { Text(title).font(.hf(.secondary, weight: .semibold)) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line).font(.hf(.secondary)).textSelection(.enabled) }
            }
            .foregroundStyle(Color.primaryText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("menu-bar-question-result")
            if action == .open { Button("Open", action: open).buttonStyle(.borderless).controlSize(.small) }
        case .editing, .submitting, .failed, .unknown:
            field
            if case .failed(let message, let code) = state.phase {
                Text(message)
.font(.hf(.secondary))
.foregroundStyle(Color.failedRed)
.textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu-bar-question-error")
                if let code { DetailLine(label: "Code", value: code) }
            }
            if let status {
                Text(status)
.font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
.fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu-bar-question-status")
            }
            actions
        }
    }

    private var field: some View {
        TextField("Type an answer", text: Binding(get: { state.draft }, set: edit))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .disabled(!state.fieldEnabled)
            .onSubmit(submit)
            .accessibilityLabel("Your answer")
            .accessibilityIdentifier("menu-bar-question-field")
    }

    private var status: String? {
        switch state.phase {
        case .submitting: MenuBarQuestionState.submittingStatus
        case .unknown: MenuBarQuestionState.unknownStatus
        case .editing, .failed, .settled: nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            switch state.phase {
            case .unknown:
                Button("Open Needs you", action: open).buttonStyle(.borderless).controlSize(.small)
            case .submitting:
                Button("Submitting…") {}.buttonStyle(MonitorButtonStyle(.primary)).disabled(true)
            case .failed:
                answerButton
                Button("Open in Harflow", action: open).buttonStyle(.borderless).controlSize(.small)
            case .editing:
                answerButton
            case .settled:
                EmptyView()
            }
        }
    }

    private var answerButton: some View {
        Button("Answer", action: submit)
            .buttonStyle(MonitorButtonStyle(.primary))
            .disabled(!state.canSubmit)
            .accessibilityIdentifier("menu-bar-question-answer")
    }
}

#if DEBUG
#Preview("Question typing") {
    MenuBarQuestionCard(title: "Nightly dependency audit", text: "Upgrade pydantic to 3.x?",
                        state: .init(draft: "Yes, upgrade to 3.x."), edit: { _ in }, submit: {}, open: {})
        .frame(width: 348)
.padding()
}

#Preview("Question failed") {
    MenuBarQuestionCard(title: "Nightly dependency audit", text: "Upgrade pydantic to 3.x?",
                        state: .init(draft: "Yes", phase: .failed(message: "The workflow is busy.", code: "workflow_error")),
                        edit: { _ in }, submit: {}, open: {})
        .frame(width: 348)
.padding()
}

#Preview("Question settled") {
    MenuBarQuestionCard(title: "Nightly dependency audit", text: "Upgrade pydantic to 3.x?",
                        state: .init(phase: .settled(title: "Answered", lines: ["Yes", "Nightly dependency audit no longer needs you."], action: .none)),
                        edit: { _ in }, submit: {}, open: {})
        .frame(width: 348)
.padding()
}
#endif
