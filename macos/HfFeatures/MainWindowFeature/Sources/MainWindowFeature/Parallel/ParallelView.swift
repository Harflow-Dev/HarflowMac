//
//  ParallelView.swift
//  MainWindowFeature
//
//  Ported from the app target's `ParallelView.swift`. One column per top-level member of a `group`;
//  the final summary is rendered as the agent wrote it (markdown), nothing is classified or tagged
//  by the app. Behaviour is unchanged except the outcome line's red-on-refusal colouring — see
//  `ParallelVM`'s header comment.
//

import HfCommon
import HfUI
import SwiftUI

// MARK: - ParallelViewModel

/// View model protocol for the Parallel screen.
@MainActor
protocol ParallelViewModel: ViewModel {

    var groupName: String { get }
    /// The header's truthful current-status counts ("1 running · 1 done"), or `nil` when nothing
    /// can be counted. Pure presentation from the complete current membership.
    var statusSummary: String? { get }
    var showPrompt: Bool { get }
    var canCancelAll: Bool { get }
    var isEmpty: Bool { get }
    var columns: [ParallelColumnModel] { get }
    var horizontalPosition: ParallelViewportPosition? { get }

    func didAppear()
    func didDisappear()
    func didTapViewPrompt()
    func didTapCancelAll()
    func updateViewport(offset: CGFloat, width: CGFloat)
    func columnState(for id: String) -> ParallelColumnUIState
}

extension ParallelViewModel {
    var horizontalPosition: ParallelViewportPosition? { nil }
    func updateViewport(offset: CGFloat, width: CGFloat) {}
    func columnState(for id: String) -> ParallelColumnUIState { ParallelColumnUIState() }
}

// MARK: - ParallelView

struct ParallelView<VM: ParallelViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    private let initiallyPrepared: Bool
    
    // MARK: - Init
    
    init(_ viewModel: VM, initiallyPrepared: Bool = false) {
        self.initiallyPrepared = initiallyPrepared
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
        Group {
            if initiallyPrepared {
                mountedContent
            } else {
                DeferredContent { placeholderContent } content: { mountedContent }
            }
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var mountedContent: some View {
        withToolbar { realContent }
            .onAppear { viewModel.didAppear() }
            .onDisappear { viewModel.didDisappear() }
    }

    private var realContent: some View {
        GeometryReader { screen in
            VStack(spacing: HfRadius.Metrics.zero) {
                if viewModel.isEmpty {
                    Text("No tasks in this group any more.")
                        .font(TaskScreenStyle.sans(size: 14))
                        .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 14, lineHeight: 22)))
                        .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                        .multilineTextAlignment(.center)
                        .padding(TaskScreenStyle.Scale.space5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Design point 3: columns fill the available width instead of a fixed 900pt budget —
                    // `GeometryReader` reads the row's actual width so `ParallelLayout.columnWidth(memberCount:availableWidth:)`
                    // can divide it evenly, keeping the 360pt lane floor (and the horizontal scroll) once there
                    // are too many members for the window to fit. The lanes start directly under the toolbar.
                    GeometryReader { proxy in
                        ScrollView(.horizontal) {
                            ParallelColumnsContent(columns: viewModel.columns, availableSize: proxy.size,
                                                   horizontalPosition: viewModel.horizontalPosition,
                                                   stateForColumn: viewModel.columnState(for:),
                                                   onViewport: { viewModel.updateViewport(offset: $0, width: $1) })
                                // The document probe (§6.5): inside the real lane's own document, so
                                // it can only ever target this horizontal scroll view.
                                .background(ScrollChrome())
                        }
                    }
                }
            }
            .frame(width: screen.size.width, height: screen.size.height, alignment: .top)
        }
    }

    /// The group's title, badge and enforcement sentence live in the window's top bar (published by the VM); the two
    /// actions sit beside them on the bare toolbar, in the group top bar's button styles.
    private func withToolbar(@ViewBuilder content: () -> some View) -> some View {
        content().toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) { viewPromptButton }.sharedBackgroundVisibility(.hidden)
            if viewModel.canCancelAll {
                ToolbarItem(placement: .primaryAction) { cancelAllButton }.sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var viewPromptButton: some View {
        Button("View prompt") { viewModel.didTapViewPrompt() }
            .buttonStyle(TopBarButtonStyle(kind: .ghost, isSelected: viewModel.showPrompt))
            .disabled(viewModel.isEmpty)
            .accessibilityAddTraits(viewModel.showPrompt ? .isSelected : [])
    }

    private var cancelAllButton: some View {
        Button("Cancel all") { viewModel.didTapCancelAll() }.buttonStyle(TopBarButtonStyle(kind: .danger))
    }

    /// The deferred first frame: a header skeleton plus N column skeletons. N is whatever is cheaply
    /// known at this point (`viewModel.columns.count`, read with no extra cost since the VM already
    /// holds it) — for a genuinely fresh selection that is always 0 (the VM hasn't subscribed yet, by
    /// design: `didAppear()` lives on `realContent`, not here), so this falls back to 2, a reasonable
    /// guess for "a group" without overcommitting to an exact count nothing here can know yet.
    private var placeholderContent: some View {
        let columnCount = viewModel.columns.isEmpty ? 2 : viewModel.columns.count
        return VStack(spacing: HfRadius.Metrics.zero) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
                    SkeletonBlock(width: HfRadius.Metrics.parallelSkeletonTitleWidth, height: HfRadius.Metrics.parallelSkeletonTitleHeight)
                    SkeletonBlock(width: HfRadius.Metrics.parallelSkeletonMetaWidth, height: HfRadius.Metrics.spacing12)
                }
                Spacer()
            }
            .padding(.horizontal, HfRadius.Metrics.spacing16)
            .padding(.vertical, HfRadius.Metrics.spacing12)
            Divider()
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: HfRadius.Metrics.zero) {
                        ForEach(0 ..< columnCount, id: \.self) { _ in
                            columnPlaceholder
                                .frame(
                                    width: ParallelLayout.columnWidth(memberCount: columnCount, availableWidth: proxy.size.width),
                                    height: max(0, proxy.size.height)
                                )
                            ParallelLaneSeparator(chrome: .lane)
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
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    SkeletonBlock(width: HfRadius.Metrics.parallelSkeletonAvatarSize, height: HfRadius.Metrics.parallelSkeletonAvatarSize,
                                  cornerRadius: HfRadius.Metrics.parallelSkeletonAvatarRadius)
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                        SkeletonBlock(width: HfRadius.Metrics.parallelSkeletonColumnTitleWidth, height: HfRadius.Metrics.spacing14)
                        SkeletonBlock(width: HfRadius.Metrics.parallelSkeletonColumnMetaWidth, height: HfRadius.Metrics.spacing10)
                    }
                }
                Divider()
                SkeletonRows(count: 4, showsBadge: false)
                Spacer(minLength: HfRadius.Metrics.zero)
            }
            .padding(HfRadius.Metrics.spacing16)
        }
    }
}

#if DEBUG
#Preview("Parallel - light") {
    ParallelView(ParallelViewModelMock())
        .frame(width: HfRadius.Metrics.toolbarPreviewWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Parallel - dark") {
    ParallelView(ParallelViewModelMock())
        .frame(width: HfRadius.Metrics.toolbarPreviewWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Parallel, empty - light") {
    ParallelView(ParallelViewModelMock(statusSummary: nil, canCancelAll: false, isEmpty: true, columns: []))
        .frame(width: HfRadius.Metrics.toolbarPreviewWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}
#endif
