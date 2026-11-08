//
//  TaskTopBarChipViews.swift
//  MainWindowFeature
//
//  The trailing chips of the standalone toolbar: observation resumed, notices and access. Each reveals its facts
//  group in the right pane. Design reference: HarflowDesign 17739e4, `.hd-m05-chip`.
//

import HfUI
import SwiftUI

// MARK: - TaskTopBarChipStyle

/// The `.hd-m05-chip` look: a 24 point outlined capsule that fills on hover.
struct TaskTopBarChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        private typealias Metrics = TaskScreenStyle.Chip

        var body: some View {
            configuration.label
                .font(.hf(.secondary))
                .foregroundStyle((hovering ? Metrics.hoverColor : Metrics.color).color)
                .padding(.horizontal, Metrics.paddingHorizontal)
                .frame(height: Metrics.height)
                .background(Capsule().fill(hovering || configuration.isPressed ? Metrics.hoverFill.color : Color.clear))
                .overlay(Capsule().stroke(Metrics.borderColor.color, lineWidth: Metrics.borderWidth))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - TaskTopBarChip

/// One chip: an icon and, when wide, its text. Narrow keeps the icon, or the count for notices.
struct TaskTopBarChip: View {
    let icon: String
    /// `nil` draws the icon alone.
    let text: String?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TaskScreenStyle.Chip.gap) {
                Image(systemName: icon).accessibilityHidden(true)
                if let text { Text(text).lineLimit(1).monospacedDigit() }
            }
            .fixedSize()
        }
        .buttonStyle(TaskTopBarChipStyle())
        .modifier(StandaloneFocusable(isEnabled: true))
        .help(help)
        .accessibilityLabel(help)
    }
}
