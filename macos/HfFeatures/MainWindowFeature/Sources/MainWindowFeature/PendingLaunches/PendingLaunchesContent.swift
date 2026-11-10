import HfUI
import SwiftUI

// MARK: - PendingLaunchesContent

/// The read-only list: a status card, the launch rows and a locked composer, in every state.
struct PendingLaunchesContent: View {
    let presentation: PendingLaunchesPresentation
    let onCheckAgain: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var motionOverride
    @Environment(\.shimmerReduceMotionOverride) private var shimmerOverride

    private var reduceMotion: Bool { motionOverride ?? shimmerOverride ?? systemReduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    card
                    if presentation.kind == .loading {
                        PendingLaunchesSkeletonRows(reduceMotion: reduceMotion)
                    } else if !presentation.rows.isEmpty {
                        rows
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
        .accessibilityIdentifier("pending-launches")
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
            if presentation.checkAction != .hidden {
                Button("Check again", action: onCheckAgain)
                    .buttonStyle(.bordered)
                    .disabled(presentation.checkAction == .disabled)
                    .padding(.top, 8)
                    .accessibilityIdentifier("pending-launches-check-again")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presentation.rows) { row in
                PendingLaunchRowView(row: row)
            }
        }
    }
}

// MARK: - PendingLaunchRowView

/// A static row in this slice; selection arrives with the detail view.
struct PendingLaunchRowView: View {
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
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
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
            ForEach(0 ..< 2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 190, height: 12)
                    bar(width: 190, height: 10)
                    bar(width: 140, height: 10)
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

    @ViewBuilder private func bar(width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5).fill(Color.neutralFill).frame(width: width, height: height)
        if reduceMotion {
            shape
        } else {
            shape.shimmering().environment(\.shimmerReduceMotionOverride, false)
        }
    }
}
