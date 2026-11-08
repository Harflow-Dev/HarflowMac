//
//  FactsGroupView.swift
//  MainWindowFeature
//
//  One collapsible group of the Events tab's facts list (`.hd-m05-facts`, HarflowDesign 17739e4): a chevron,
//  a 13 point medium title, an optional right-aligned count and a bordered body. The header is focusable so a
//  reveal can move focus into it.
//

import SwiftUI

// MARK: - TaskPaneFocus

/// The focus bindings a reveal drives: keyboard focus and the VoiceOver cursor, both onto a facts group header.
struct TaskPaneFocus {
    let group: FocusState<TaskPaneStateStore.FactsGroup?>.Binding
    let accessibilityGroup: AccessibilityFocusState<TaskPaneStateStore.FactsGroup?>.Binding
}

// MARK: - FactsGroupView

/// A facts group. Expansion is owned by the caller so it survives the pane being closed.
struct FactsGroupView<Content: View>: View {
    let group: TaskPaneStateStore.FactsGroup
    let title: String
    var count: Int?
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void
    let focus: TaskPaneFocus
    @ViewBuilder let content: () -> Content

    /// The chevron's point size; the design draws a 12 point icon box, scaled to sit on the 13 point title.
    private static var chevronSize: CGFloat { 10 }

    var body: some View {
        let summary = TaskScreenStyle.FactsSummary.self
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                content()
                    .font(TaskScreenStyle.sans(size: TaskScreenStyle.FactsBody.text.size))
                    .padding(.leading, TaskScreenStyle.FactsBody.paddingLeading)
                    .padding(.bottom, TaskScreenStyle.FactsBody.paddingBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(summary.borderColor.color).frame(height: summary.borderWidth)
        }
        .id(group)
    }

    private var header: some View {
        let summary = TaskScreenStyle.FactsSummary.self
        return HStack(spacing: summary.gap) {
            Image(systemName: "chevron.right")
                .font(TaskScreenStyle.sans(size: Self.chevronSize).weight(.semibold))
                .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                .rotationEffect(.degrees(isExpanded ? summary.expandedChevronDegrees : 0))
                .frame(width: Self.chevronSize)
                .accessibilityHidden(true)
            Text(title)
                .font(TaskScreenStyle.sans(size: summary.fontSize).weight(summary.weight))
                .foregroundStyle(TaskScreenStyle.Colors.text.color)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(TaskScreenStyle.sans(size: TaskScreenStyle.PaneTab.countSize))
                    .monospacedDigit()
                    .foregroundStyle(TaskScreenStyle.PaneTab.countColor.color)
            }
        }
        .frame(minHeight: summary.minHeight)
        .contentShape(Rectangle())
        .focusable()
        .focused(focus.group, equals: group)
        .accessibilityFocused(focus.accessibilityGroup, equals: group)
        .onTapGesture { setExpanded(!isExpanded) }
        .onKeyPress(keys: [.space, .return]) { _ in
            setExpanded(!isExpanded)
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAction { setExpanded(!isExpanded) }
    }
}

// MARK: - FactsGrid

/// The two column definition list inside a group body (`.hd-m05-facts dl`): a tertiary term, then its value.
struct FactsGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: TaskScreenStyle.FactsBody.columnGap, verticalSpacing: TaskScreenStyle.FactsBody.rowGap) {
            content()
        }
        .font(TaskScreenStyle.sans(size: TaskScreenStyle.FactsBody.listText.size))
        .padding(.vertical, TaskScreenStyle.FactsBody.listMarginVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - FactsRow

/// One term and its value inside a `FactsGrid`.
func factsRow(_ term: String, _ value: String, help: String? = nil) -> some View {
    GridRow {
        Text(term).foregroundStyle(TaskScreenStyle.FactsBody.termColor.color)
        factsValue(value, help: help)
    }
}

@ViewBuilder
private func factsValue(_ value: String, help: String?) -> some View {
    let text = Text(verbatim: value)
        .foregroundStyle(TaskScreenStyle.Colors.text.color)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    if let help { text.help(help) } else { text }
}

// MARK: - FactsCaption

/// `.hd-m05-caption` under a group body.
struct FactsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TaskScreenStyle.sans(size: TaskScreenStyle.FactsBody.listText.size))
            .foregroundStyle(TaskScreenStyle.FactsBody.termColor.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
