//
//  TopBarButtonStyle.swift
//  MainWindowFeature
//
//  The group top bar's buttons: `.hd-btn--ghost` (View prompt) and `.hd-btn--danger` (Cancel all). Design reference:
//  HarflowDesign 4ff7d83, `bundle.css` `.hd-btn`.
//

import SwiftUI

// MARK: - TopBarButtonStyle

/// 32 pt tall, 12 pt side padding, 13/18 weight 500. Ghost is `text-secondary` with a hover fill; danger is a
/// `surface` fill with a `border` outline and `danger` text (hover `danger-subtle`). A disabled button is at 45%.
struct TopBarButtonStyle: ButtonStyle {
    enum Kind { case ghost, danger }

    static let paddingHorizontal: CGFloat = 12
    static let height: CGFloat = 32

    let kind: Kind
    var isSelected = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, isSelected: isSelected, isEnabled: isEnabled)
    }

    struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let isSelected: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusMedium)
            configuration.label
                .font(TaskScreenStyle.sans(size: 13, weight: .medium))
                .foregroundStyle(foreground.color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, TopBarButtonStyle.paddingHorizontal)
                .frame(height: TopBarButtonStyle.height)
                .background(shape.fill(fill))
                .overlay { if kind == .danger { shape.strokeBorder(TaskScreenStyle.Colors.border.color, lineWidth: 1) } }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }

        private var foreground: TaskScreenStyle.Token {
            switch kind {
            case .ghost: hovering || isSelected ? TaskScreenStyle.Colors.text : TaskScreenStyle.Colors.textSecondary
            case .danger: TaskScreenStyle.Colors.danger
            }
        }

        private var fill: Color {
            switch kind {
            case .ghost: hovering || isSelected || configuration.isPressed ? TaskScreenStyle.Colors.surfaceHover.color : .clear
            case .danger: (hovering || configuration.isPressed ? TaskScreenStyle.Colors.dangerSubtle : TaskScreenStyle.Colors.surface).color
            }
        }
    }
}
