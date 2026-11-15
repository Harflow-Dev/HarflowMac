//
//  TaskTopBarPrincipal.swift
//  MainWindowFeature
//
//  The window toolbar's single principal item. For a standalone task it draws the title, status badge and meta
//  from `TaskTopBarHolder.shownSlot`: the loaded content, or the loading shape while the task is read (the pre-mount
//  slot state stands in until the task view publishes). For every other selection, and for a task that was not found,
//  it draws the shell's context title. It is the only reader of the holder.
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
    /// The page shape drawn while a page-level screen has not published yet (pending launches), so the bar never
    /// shows the shell's text and then restyles. `nil` for every other selection.
    var fallbackPage: PageTopBarContent?
    /// Native regression probe; production leaves this nil.
    var onEvaluation: (() -> Void)?

    /// Whether meta is hidden: before the first layout pass (so a dropped meta never flashes) and whenever the solver
    /// dropped it. Taken from the solver's explicit result through the probe, never from a measured width.
    @State private var metaHidden = true
    @State private var groupMetaCollapsed = true
    @State private var probe = TopBarLayoutProbe()

    private typealias Metrics = TaskScreenStyle.TopBar

    /// The reserved width of the busy spinner's slot: a small system progress indicator.
    static let busySlotWidth: CGFloat = 16

    var body: some View {
        _ = onEvaluation?()
        if let group = holder.shownGroup { return AnyView(groupBody(group)) }
        if let page = holder.shownPage ?? fallbackPage { return AnyView(pageBody(page)) }
        let slot = holder.shownSlot ?? holder.preMountSlot
        if case .loading(let title) = slot { return AnyView(taskLoadingBody(title: title)) }
        let content = slot?.content
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

    // MARK: Task loading

    /// The standalone task while it loads (`task/loading` and `task/loading-known-title`, HarflowDesign 9709483): the
    /// known title drawn as the loaded bar draws it, else a title block, then a badge pill, the busy slot and a meta
    /// block. Not-found and the frames with nothing to show draw the caption instead.
    private func taskLoadingBody(title: String?) -> some View {
        let band = layout.effectiveBand
        return TopBarPrincipalLayout(cap: band.cap, probe: probe) {
            Group {
                if let title, !title.isEmpty {
                    taskTitle(title)
                } else {
                    SkeletonBlock(width: Self.loadingTitleSize.width, height: Self.loadingTitleSize.height)
                        .accessibilityHidden(true)
                }
            }
            .topBarRole(.title)
            SkeletonBlock(width: Self.loadingBadgeWidth, height: TaskScreenStyle.Badge.height, cornerRadius: TaskScreenStyle.Badge.height / 2)
                .accessibilityHidden(true)
                .topBarRole(.badge)
            Color.clear.frame(width: Self.busySlotWidth, height: Self.busySlotWidth).accessibilityHidden(true).topBarRole(.busy)
            // The meta follows the loaded meta's rule: absent when the window is narrow.
            if !band.isNarrow {
                loadingMetaBlock(width: Self.loadingMetaSize.width, height: Self.loadingMetaSize.height).topBarRole(.meta)
            }
            status.topBarRole(.status)
        }
        .accessibilityElement(children: .contain)
    }

    /// `task/loading` title block: 190 by 14 (`skeleton-specs.js`, `S['task']`).
    static let loadingTitleSize = CGSize(width: 190, height: 14)
    /// `task/loading` meta block: 170 by 10, dropped by the solver when it does not fit.
    static let loadingMetaSize = CGSize(width: 170, height: 10)
    /// The badge pill fills the loaded badge's box: 22 pt high (`TaskScreenStyle.Badge.height`) and as wide as the
    /// template badge in `task/running-stop`: 8 + 10 (spinner) + 5 (gap) + about 83 ("Running 04:12" at 12 pt medium)
    /// + 8.
    static let loadingBadgeWidth: CGFloat = 114

    // MARK: Page

    /// A page-level screen: a single-line title and one badge. No meta, busy slot or buttons.
    private func pageBody(_ page: PageTopBarContent) -> some View {
        TopBarPrincipalLayout(cap: layout.effectiveBand.cap, probe: probe) {
            Text(page.title)
                .font(.hf(.reading, weight: Metrics.titleWeight))
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(page.title)
                .accessibilityLabel(page.title)
                .topBarRole(.title)
            TaskStatusBadge(model: page.badge).topBarRole(.badge)
            status.topBarRole(.status)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Group

    /// A Parallel group: title, badge and meta in the group's own width budget (the detail column minus both toolbar
    /// buttons and the bar's margins). The badge stays whole; the meta is whole or dropped, never shortened.
    private func groupBody(_ group: GroupTopBarContent) -> some View {
        let cap = layout.detailWidth.map { GroupTopBarBudget.cap(detailWidth: $0, windowWidth: layout.windowWidth) } ?? layout.effectiveBand.cap
        return TopBarPrincipalLayout(cap: cap, probe: probe, titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false) {
            Text(group.title)
                .font(.hf(.reading, weight: Metrics.titleWeight))
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.title)
                .accessibilityLabel(group.title)
                .topBarRole(.title)
            if group.isLoading {
                // Membership is unknown: a 150 pt badge block and a 300 pt meta block (dropped when it does not fit).
                SkeletonBlock(width: 150, height: 12).topBarRole(.badge)
                loadingMetaBlock(width: 300, height: 12).topBarRole(.meta)
            } else {
                if let badge = group.badge { TaskStatusBadge(model: badge).topBarRole(.badge) }
                if let meta = group.meta {
                    groupMeta(meta).topBarRole(.meta)
                    TopBarMetaDot(sentence: meta).topBarRole(.dot)
                }
            }
            status.topBarRole(.status)
        }
        .accessibilityElement(children: .contain)
    }

    private func loadingMetaBlock(width: CGFloat, height: CGFloat) -> some View {
        let block = SkeletonBlock(width: width, height: height).fixedSize()
        return block.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped().accessibilityHidden(true)
    }

    /// Whole at its ideal width. A dropped meta is placed with a zero width, so the clipped frame draws nothing; it stays
    /// in the accessibility tree (the minimum-window dot that will carry it is a later slice). No state is involved, so
    /// there is nothing to go stale between layout passes.
    private func groupMeta(_ meta: String) -> some View {
        Text(meta)
            .font(.hf(.secondary))
            .foregroundStyle(Metrics.metaColor.color)
            .lineLimit(1)
            // Flexible like the task meta: the layout proposes the whole ideal width (no truncation can occur) or zero
            // (nothing is drawn), so a dropped meta has no frame and cannot spill past the principal's bounds.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            // One element for the frame itself, so its accessibility frame is the drawn width (zero when dropped).
            // A dropped meta (no drawn width) is spoken by the dot, once. Derived from the drawn width, so it cannot go stale.
            .accessibilityHidden(groupMetaCollapsed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meta)
            .accessibilityIdentifier("group-top-bar.meta")
            .onGeometryChange(for: Bool.self) { $0.size.width < 1 } action: { groupMetaCollapsed = $0 }
    }

    /// The task title as the loaded bar draws it; the loading bar uses the same view.
    private func taskTitle(_ title: String) -> some View {
        Text(title)
            .font(.hf(.reading, weight: Metrics.titleWeight))
            .foregroundStyle(Color.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(title)
            .accessibilityLabel(title)
    }

    @ViewBuilder private func titleText(_ content: TaskTopBarContent?) -> some View {
        if let content, !content.title.isEmpty {
            taskTitle(content.title)
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

#if DEBUG
@MainActor
private func loadingPreview(title: String?, width: CGFloat) -> some View {
    let holder = TaskTopBarHolder()
    holder.setPreMountSlot(.loading(title: title))
    let layout = TopBarLayoutState()
    layout.setBand(TopBarWidthBand(width: width))
    return TaskTopBarPrincipal(holder: holder, layout: layout, fallbackTitle: "Harflow · Work", status: AnyView(EmptyView()))
        .frame(width: width, height: 52)
}

#Preview("Task loading, title known") { loadingPreview(title: "Review preload bridge", width: 1280) }
#Preview("Task loading, title unknown") { loadingPreview(title: nil, width: 1280) }
#Preview("Task loading, title known, narrow") { loadingPreview(title: "Review preload bridge", width: 1000) }
#endif
