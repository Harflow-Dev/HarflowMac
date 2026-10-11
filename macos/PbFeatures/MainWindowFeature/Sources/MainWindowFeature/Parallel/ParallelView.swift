//
//  ParallelView.swift
//  MainWindowFeature
//
//  Ported from the app target's `ParallelView.swift`. One column per top-level member of a `group`;
//  the final summary is rendered as the agent wrote it (markdown), nothing is classified or tagged
//  by the app. Behaviour is unchanged except the outcome line's red-on-refusal colouring — see
//  `ParallelVM`'s header comment.
//

import PbCommon
import PbUI
import SwiftUI

// MARK: - ParallelViewModel

/// View model protocol for the Parallel screen.
@MainActor
protocol ParallelViewModel: ViewModel {

    var groupName: String { get }
    var headerSubtitle: String { get }
    /// The header's truthful current-status counts ("1 running · 1 done"), or `nil` when nothing
    /// can be counted. Pure presentation from the complete current membership.
    var statusSummary: String? { get }
    /// The common enforcement claims every current member makes, as short pills; empty when none
    /// can be derived.
    var headerPills: [String] { get }
    /// The non-pill common clauses under the pills — or, when no pill can be derived, the
    /// unchanged common/fallback sentence. Empty means no caption.
    var headerClaimCaption: String { get }
    var showPrompt: Bool { get }
    var canCancelAll: Bool { get }
    var isEmpty: Bool { get }
    var columns: [ParallelColumnModel] { get }

    func didAppear()
    func didDisappear()
    func didTapViewPrompt()
    func didTapCancelAll()
    func updateViewport(offset: CGFloat, width: CGFloat)
    func columnState(for id: String) -> ParallelColumnUIState
}

extension ParallelViewModel {
    func updateViewport(offset: CGFloat, width: CGFloat) {}
    func columnState(for id: String) -> ParallelColumnUIState { ParallelColumnUIState() }
}

// MARK: - ParallelView

struct ParallelView<VM: ParallelViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body

    /// Monitor piece 12, Design point 2: `DeferredContent` shows `placeholderContent` on the first
    /// frame, so picking a group changes the page instantly instead of freezing while every column's
    /// layout builds. Lives INSIDE the coordinator's per-group `.id(name)` (applied at the
    /// `buildParallelView(name:)` call site, wrapping this whole view) so a new group selection gets
    /// a fresh `DeferredContentState` and starts on the placeholder again, while re-renders of the
    /// SAME group never flash it a second time. `didAppear()`/`didDisappear()` stay on
    /// `realContent`, not the placeholder, so leases start once the real screen actually mounts —
    /// one committed frame after the selection, not on the very first frame.
    var body: some View {
        DeferredContent {
            placeholderContent
        } content: {
            withToolbar { realContent }
                .onAppear { viewModel.didAppear() }
                .onDisappear { viewModel.didDisappear() }
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var realContent: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            if viewModel.isEmpty {
                Text("No tasks in this group any more.").font(.pb(.body)).foregroundStyle(Color.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                claimStrip
                // Design point 3: columns fill the available width instead of a fixed 900pt budget —
                // `GeometryReader` reads the row's actual width so `ParallelLayout.columnWidth(memberCount:availableWidth:)`
                // can divide it evenly, keeping the 420pt reading-width floor (and the horizontal scroll) once there
                // are too many members for the window to fit.
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        ParallelColumnsContent(columns: viewModel.columns, availableSize: proxy.size,
                                               stateForColumn: viewModel.columnState(for:),
                                               onViewport: { viewModel.updateViewport(offset: $0, width: $1) })
                            // The document probe (§6.5): inside the real lane's own document, so
                            // it can only ever target this horizontal scroll view.
                            .background(ScrollChrome())
                    }
                }
            }
        }
    }

    /// SPEC §4/§6.5: the group's common enforcement claims — pills for the clauses that are
    /// already short enough to be one, the rest (or, when no pill can be derived, the unchanged
    /// common/fallback sentence) as a caption — in a content-top strip ABOVE the lanes, never the
    /// toolbar. The header's claim inputs stay out of the toolbar's consumed fields entirely, so
    /// enforcement-only changes leave the toolbar presentation quiet.
    private var claimStrip: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            if !viewModel.headerPills.isEmpty {
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    ForEach(viewModel.headerPills, id: \.self) { label in
                        Text(label)
                            .font(.pb(.secondary, weight: .semibold))
                            .foregroundStyle(Color.secondaryText)
                            .padding(.horizontal, PbRadius.Metrics.parallelPillHorizontalPadding)
                            .padding(.vertical, PbRadius.Metrics.parallelPillVerticalPadding)
                            .background(Capsule().fill(Color.pillFill))
                    }
                    Spacer(minLength: PbRadius.Metrics.zero)
                }
            }
            if !viewModel.headerClaimCaption.isEmpty {
                Text(viewModel.headerClaimCaption)
                    .font(.pb(.caption))
                    .foregroundStyle(Color.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, PbRadius.Metrics.spacing16)
        .padding(.top, PbRadius.Metrics.spacing12)
        .padding(.bottom, PbRadius.Metrics.spacing8)
        .accessibilityElement(children: .combine)
    }

    /// The group's header lives in the window's toolbar row, as the task detail's does. The title
    /// sits on the bare toolbar (no glass capsule) and a spacer pushes the actions trailing.
    private func withToolbar(@ViewBuilder content: () -> some View) -> some View {
        content().toolbar {
            ToolbarItem(placement: .navigation) { groupTitle }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            // The task screen's quiet buttons, each on the bare toolbar — no glass capsule.
            ToolbarItem(placement: .primaryAction) { viewPromptButton }.sharedBackgroundVisibility(.hidden)
            if viewModel.canCancelAll {
                ToolbarItem(placement: .primaryAction) { cancelAllButton }.sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var groupTitle: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
            Text(viewModel.groupName).font(.pb(.title, weight: .semibold)).lineLimit(1)
            Text(viewModel.headerSubtitle).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).lineLimit(1)
            // NEW truthful status counts (§6.5) from the complete current membership — complete
            // toolbar equality includes this field, so a status change refreshes it while
            // duplicate snapshots/feeds stay quiet.
            if let statusSummary = viewModel.statusSummary {
                Text(statusSummary).font(.pb(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText).lineLimit(1)
            }
        }
    }

    private var viewPromptButton: some View {
        Button("View prompt") { viewModel.didTapViewPrompt() }.buttonStyle(MonitorButtonStyle(.glass))
    }

    private var cancelAllButton: some View {
        Button("Cancel all", role: .destructive) { viewModel.didTapCancelAll() }.buttonStyle(QuietButtonStyle())
    }

    /// The deferred first frame: a header skeleton plus N column skeletons. N is whatever is cheaply
    /// known at this point (`viewModel.columns.count`, read with no extra cost since the VM already
    /// holds it) — for a genuinely fresh selection that is always 0 (the VM hasn't subscribed yet, by
    /// design: `didAppear()` lives on `realContent`, not here), so this falls back to 2, a reasonable
    /// guess for "a group" without overcommitting to an exact count nothing here can know yet.
    private var placeholderContent: some View {
        let columnCount = viewModel.columns.isEmpty ? 2 : viewModel.columns.count
        return VStack(spacing: PbRadius.Metrics.zero) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                    SkeletonBlock(width: PbRadius.Metrics.parallelSkeletonTitleWidth, height: PbRadius.Metrics.parallelSkeletonTitleHeight)
                    SkeletonBlock(width: PbRadius.Metrics.parallelSkeletonMetaWidth, height: PbRadius.Metrics.spacing12)
                }
                Spacer()
            }
            .padding(.horizontal, PbRadius.Metrics.spacing16)
            .padding(.vertical, PbRadius.Metrics.spacing12)
            Divider()
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: PbRadius.Metrics.zero) {
                        ForEach(0 ..< columnCount, id: \.self) { _ in
                            columnPlaceholder
                                .frame(
                                    width: ParallelLayout.columnWidth(memberCount: columnCount, availableWidth: proxy.size.width),
                                    height: max(0, proxy.size.height)
                                )
                            Divider()
                        }
                    }
                    // The document probe (§6.5): inside the loading lane's own document.
                    .background(ScrollChrome())
                }
            }
        }
    }

    private var columnPlaceholder: some View {
        ParallelLaneSurface {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    SkeletonBlock(width: PbRadius.Metrics.parallelSkeletonAvatarSize, height: PbRadius.Metrics.parallelSkeletonAvatarSize,
                                  cornerRadius: PbRadius.Metrics.parallelSkeletonAvatarRadius)
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                        SkeletonBlock(width: PbRadius.Metrics.parallelSkeletonColumnTitleWidth, height: PbRadius.Metrics.spacing14)
                        SkeletonBlock(width: PbRadius.Metrics.parallelSkeletonColumnMetaWidth, height: PbRadius.Metrics.spacing10)
                    }
                }
                Divider()
                SkeletonRows(count: 4, showsBadge: false)
                Spacer(minLength: PbRadius.Metrics.zero)
            }
            .padding(PbRadius.Metrics.spacing16)
        }
    }
}

#if DEBUG
#Preview("Parallel - light") {
    ParallelView(ParallelViewModelMock())
        .frame(width: PbRadius.Metrics.toolbarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Parallel - dark") {
    ParallelView(ParallelViewModelMock())
        .frame(width: PbRadius.Metrics.toolbarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

/// No pill can be derived here, so the caption carries the unchanged common sentence.
#Preview("Parallel, no pills - light") {
    ParallelView(ParallelViewModelMock(
        statusSummary: "2 done",
        headerPills: [],
        headerClaimCaption: "Enforced for every agent here: Network: not controlled."
    ))
    .frame(width: PbRadius.Metrics.toolbarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Parallel, no pills - dark") {
    ParallelView(ParallelViewModelMock(
        statusSummary: "2 done",
        headerPills: [],
        headerClaimCaption: "Enforced for every agent here: Network: not controlled."
    ))
    .frame(width: PbRadius.Metrics.toolbarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}
#endif
