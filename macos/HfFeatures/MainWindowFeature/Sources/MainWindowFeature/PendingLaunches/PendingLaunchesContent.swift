import AppKit
import HfUI
import SwiftUI

// MARK: - PendingLaunchesActions

/// The screen's user actions; defaults make previews and captures inert.
struct PendingLaunchesActions {
    var checkAgain: () -> Void = {}
    var select: (String) -> Void = { _ in }
    var back: () -> Void = {}
    var detailCheckAgain: () -> Void = {}
    var checkTaskStatus: () -> Void = {}
}

// MARK: - PendingLaunchesContent

/// The list or the selected launch's detail, above a locked composer that stays in every state.
struct PendingLaunchesContent: View {
    let presentation: PendingLaunchesPresentation
    var detail: PendingLaunchDetailPresentation?
    var focusRowID: String?
    var actions = PendingLaunchesActions()

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var motionOverride
    @Environment(\.shimmerReduceMotionOverride) private var shimmerOverride
    @FocusState private var focusedRow: String?

    private var reduceMotion: Bool { motionOverride ?? shimmerOverride ?? systemReduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if let detail {
                        PendingLaunchDetailBody(detail: detail, reduceMotion: reduceMotion, actions: actions)
                    } else {
                        inventory
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
            PendingLaunchesLockedComposer()
        }
        .background(Color.windowBG)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail?.title ?? presentation.title)
        .accessibilityIdentifier("pending-launches")
        .onChange(of: presentation.kind) { _, _ in
            if detail == nil { announce(presentation.title, presentation.message) }
        }
        .onChange(of: detail?.kind) { _, kind in
            if let detail, kind != nil { announce(detail.title, detail.message) }
        }
    }

    /// Only a change of presented state is announced; identical rebuilds never reach here.
    private func announce(_ title: String, _ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message.isEmpty ? title : "\(title). \(message)",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 20) {
            card
            if presentation.kind == .loading {
                PendingLaunchesSkeletonRows(reduceMotion: reduceMotion)
            } else if !presentation.rows.isEmpty {
                rows
            }
            if presentation.checkAction != .hidden {
                Button("Check again", action: actions.checkAgain)
                    .buttonStyle(.bordered)
                    .disabled(presentation.checkAction == .disabled)
                    .accessibilityIdentifier("pending-launches-check-again")
            }
        }
        .onAppear { DispatchQueue.main.async { focusedRow = focusRowID } }
        .onChange(of: focusRowID) { _, id in focusedRow = id }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(.hf(.title, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.message)
                .font(.hf(.body))
                .lineSpacing(4)
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presentation.rows) { row in
                PendingLaunchRowView(row: row, focus: $focusedRow) { actions.select(row.id) }
            }
        }
    }
}

// MARK: - PendingLaunchRowView

/// A selectable row: a button whose label is the row's visible lines.
struct PendingLaunchRowView: View {
    let row: PendingLaunchesPresentation.Row
    var focus: FocusState<String?>.Binding
    var onSelect: () -> Void = {}

    var body: some View {
        // Focus lives on the button itself, so Space and Return activate it and the outline follows it.
        Button(action: onSelect) { PendingLaunchRowLabel(row: row) }
            .buttonStyle(PendingLaunchRowButtonStyle(isFocused: focus.wrappedValue == row.id))
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: row.id)
            .accessibilityLabel([row.title, row.meta, row.id].compactMap(\.self).joined(separator: ", "))
            .accessibilityIdentifier("pending-launch-row")
    }
}

// MARK: - PendingLaunchRowLabel

struct PendingLaunchRowLabel: View {
    let row: PendingLaunchesPresentation.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(.hf(.body, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            if let meta = row.meta {
                Text(meta)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
            }
            Text(row.id)
                .font(.hf(.secondary, design: .monospaced))
                .foregroundStyle(Color.primaryText)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - PendingLaunchRowButtonStyle

/// The row's outline with the list-row hover and press fill.
struct PendingLaunchRowButtonStyle: ButtonStyle {
    var isFocused = false

    func makeBody(configuration: Configuration) -> some View {
        PendingLaunchRowChrome(configuration: configuration, isFocused: isFocused)
    }
}

private struct PendingLaunchRowChrome: View {
    let configuration: ButtonStyleConfiguration
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: HfRadius.row)
                .fill(hovering || configuration.isPressed ? Color.cardFill : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder, lineWidth: 1))
            .overlay {
                // The design's `:focus-visible` outline: 2px accent, 2px outside the row.
                if isFocused {
                    RoundedRectangle(cornerRadius: HfRadius.row + 2).strokeBorder(Color.accentFill, lineWidth: 2).padding(-4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: HfRadius.row))
            .onHover { hovering = $0 }
    }
}

// MARK: - PendingLaunchesLockedComposer

/// Drawn so the window keeps its composer position; never interactive.
struct PendingLaunchesLockedComposer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Messages are unavailable until Harflow confirms the task has started", text: .constant(""))
                .textFieldStyle(.plain)
                .font(.hf(.body))
                .disabled(true)
                .frame(height: 38)
                .accessibilityLabel("Pending launch message unavailable")
            Text("Pending launch · messaging unavailable")
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
        .padding(.horizontal, 36)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}

// MARK: - PendingLaunchesSkeletonRows

struct PendingLaunchesSkeletonRows: View {
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0 ..< 2, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    PendingLaunchSkeletonBar(width: index == 0 ? 190 : 140, height: 12, reduceMotion: reduceMotion)
                    PendingLaunchSkeletonBar(width: 190, height: 10, reduceMotion: reduceMotion)
                    PendingLaunchSkeletonBar(width: 140, height: 10, reduceMotion: reduceMotion)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - PendingLaunchSkeletonBar

struct PendingLaunchSkeletonBar: View {
    let width: CGFloat
    let height: CGFloat
    let reduceMotion: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5).fill(Color.neutralFill).frame(width: width, height: height)
        if reduceMotion {
            shape
        } else {
            shape.shimmering().environment(\.shimmerReduceMotionOverride, false)
        }
    }
}
