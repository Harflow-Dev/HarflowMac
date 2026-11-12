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
                DeferredContent { ParallelLoadingContent(laneCount: loadingLaneCount) } content: { mountedContent }
            }
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var loadingLaneCount: Int {
        viewModel.columns.isEmpty ? ParallelLoadingSkeleton.defaultLaneCount : viewModel.columns.count
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
                    ParallelEmptyGroupText()
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

    private func withToolbar(@ViewBuilder content: () -> some View) -> some View {
        content().parallelGroupToolbar(
            .init(isEmpty: viewModel.isEmpty, showPrompt: viewModel.showPrompt, canCancelAll: viewModel.canCancelAll),
            onViewPrompt: viewModel.didTapViewPrompt, onCancelAll: viewModel.didTapCancelAll)
    }
}

// MARK: - ParallelEmptyGroupText

/// A group whose membership resolved to nothing: "No tasks in this group any more.", 14/22 secondary, centred.
struct ParallelEmptyGroupText: View {
    var body: some View {
        Text("No tasks in this group any more.")
            .font(TaskScreenStyle.sans(size: 14))
            .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 14, lineHeight: 22)))
            .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
            .multilineTextAlignment(.center)
            .padding(TaskScreenStyle.Scale.space5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ParallelLoadingContent

/// The group screen before its membership is known: the loading lanes under the group toolbar with both buttons disabled.
struct ParallelLoadingContent: View {
    let laneCount: Int

    var body: some View {
        ParallelLoadingSkeleton(laneCount: laneCount)
            .parallelGroupToolbar(.init(isLoading: true, canCancelAll: true), onViewPrompt: {}, onCancelAll: {})
    }
}

// MARK: - Group toolbar

/// What the group's toolbar buttons depend on.
struct ParallelGroupToolbarState {
    var isLoading = false
    var isEmpty = false
    var showPrompt = false
    var canCancelAll = false
}

extension View {
    /// The group's actions on the bare toolbar, in the group top bar's button styles: View prompt (disabled for an empty
    /// or loading group, pressed while the prompt shows) and Cancel all (danger, only while something runs; shown
    /// disabled while loading so the bar's layout does not change when the membership resolves).
    func parallelGroupToolbar(_ state: ParallelGroupToolbarState, onViewPrompt: @escaping () -> Void,
                              onCancelAll: @escaping () -> Void) -> some View {
        let (isLoading, isEmpty, showPrompt, canCancelAll) = (state.isLoading, state.isEmpty, state.showPrompt, state.canCancelAll)
        return toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button("View prompt", action: onViewPrompt)
                    .buttonStyle(TopBarButtonStyle(kind: .ghost, isSelected: showPrompt))
                    .disabled(isEmpty || isLoading)
                    .accessibilityAddTraits(showPrompt ? .isSelected : [])
            }
            .sharedBackgroundVisibility(.hidden)
            if canCancelAll {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel all", action: onCancelAll).buttonStyle(TopBarButtonStyle(kind: .danger)).disabled(isLoading)
                }
                .sharedBackgroundVisibility(.hidden)
            }
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
