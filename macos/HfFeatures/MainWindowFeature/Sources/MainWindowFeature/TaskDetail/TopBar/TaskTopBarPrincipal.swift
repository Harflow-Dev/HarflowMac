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
        if let group = holder.shownGroup { return AnyView(groupBody(group)) }
        let content = holder.shown
        let band = layout.effectiveBand
        return AnyView(TopBarPrincipalLayout(cap: band.cap, probe: probe) {
            titleText(content).topBarRole(.title)
            if let content {
                TaskStatusBadge(model: content.badge).topBarRole(.badge)
                busySlot(content).topBarRole(.busy)
                if content.showsMeta(isNarrow: band.isNarrow) { metaText(content).topBarRole(.meta) }
            }
            status.topBarRole(.status)
        }
        .accessibilityElement(children: .contain))
    }

    // MARK: Group

    /// A Parallel group: title, badge and meta in the group's own width budget (the detail column minus both toolbar
    /// buttons and the bar's margins). The badge stays whole; the meta is whole or dropped, never shortened.
    private func groupBody(_ group: GroupTopBarContent) -> some View {
        let cap = layout.detailWidth.map(GroupTopBarBudget.cap(detailWidth:)) ?? layout.effectiveBand.cap
        return TopBarPrincipalLayout(cap: cap, probe: probe, titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false) {
            Text(group.title)
                .font(.hf(.reading, weight: Metrics.titleWeight))
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.title)
                .accessibilityLabel(group.title)
                .topBarRole(.title)
            if let badge = group.badge { TaskStatusBadge(model: badge).topBarRole(.badge) }
            if let meta = group.meta, !group.isLoading { groupMeta(meta).topBarRole(.meta) }
            status.topBarRole(.status)
        }
        .accessibilityElement(children: .contain)
    }

    /// Whole at its ideal width. A dropped meta is placed with a zero width, so the clipped frame draws nothing; it stays
    /// in the accessibility tree (the minimum-window dot that will carry it is a later slice). No state is involved, so
    /// there is nothing to go stale between layout passes.
    private func groupMeta(_ meta: String) -> some View {
        Text(meta)
            .font(.hf(.secondary))
            .foregroundStyle(Metrics.metaColor.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .accessibilityIdentifier("group-top-bar.meta")
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
