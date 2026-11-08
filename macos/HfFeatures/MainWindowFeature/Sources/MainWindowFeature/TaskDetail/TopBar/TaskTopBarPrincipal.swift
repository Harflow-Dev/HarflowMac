//
//  TaskTopBarPrincipal.swift
//  MainWindowFeature
//
//  The window toolbar's single principal item. For a standalone task it draws the title, status badge and meta
//  from `TaskTopBarHolder.shown`; for every other selection, and before the live task publishes, it draws the
//  shell's context title. It is the only reader of the holder.
//

import HfUI
import SwiftUI

// MARK: - TaskTopBarPrincipal

/// The principal item's content: title, badge, busy slot, meta and the connection status, laid out inside the
/// band's cap by `TopBarPrincipalLayout`.
struct TaskTopBarPrincipal: View {
    let holder: TaskTopBarHolder
    let layout: TopBarLayoutState
    /// Shown for every selection that is not a task, and until a task publishes.
    let fallbackTitle: String
    let status: AnyView
    /// Native regression probe; production leaves this nil.
    var onEvaluation: (() -> Void)?

    /// Whether meta is hidden: before the first layout pass (so a dropped meta never flashes) and whenever the solver
    /// dropped it. Taken from the solver's explicit result through the probe, never from a measured width.
    @State private var metaHidden = true
    @State private var probe = TopBarLayoutProbe()

    private typealias Metrics = TaskScreenStyle.TopBar

    /// The reserved width of the busy spinner's slot: a small system progress indicator.
    static let busySlotWidth: CGFloat = 16

    var body: some View {
        _ = onEvaluation?()
        let content = holder.shown
        let band = layout.effectiveBand
        return TopBarPrincipalLayout(cap: band.cap, probe: probe) {
            titleText(content).topBarRole(.title)
            if let content {
                TaskStatusBadge(model: content.badge).topBarRole(.badge)
                busySlot(content).topBarRole(.busy)
                if content.showsMeta(isNarrow: band.isNarrow) { metaText(content).topBarRole(.meta) }
            }
            status.topBarRole(.status)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func titleText(_ content: TaskTopBarContent?) -> some View {
        if let content, !content.title.isEmpty {
            Text(content.title)
                .font(.hf(.reading, weight: Metrics.titleWeight))
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(content.title)
                .accessibilityLabel(content.title)
        } else {
            Text(fallbackTitle).font(.hf(.secondary)).lineLimit(1)
        }
    }

    private func metaText(_ content: TaskTopBarContent) -> some View {
        Text(content.metaText)
            .font(.hf(.secondary))
            .foregroundStyle(Metrics.metaColor.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .opacity(metaHidden ? 0 : 1)
            .accessibilityHidden(metaHidden)
            .onGeometryChange(for: Bool.self) { [probe] _ in probe.hidesMeta } action: { metaHidden = $0 }
    }

    /// A fixed slot, so a busy spinner never changes the item's width.
    private func busySlot(_ content: TaskTopBarContent) -> some View {
        ZStack {
            if content.isBusy { ProgressView().controlSize(.small) }
        }
        .frame(width: Self.busySlotWidth, height: Self.busySlotWidth)
    }
}
