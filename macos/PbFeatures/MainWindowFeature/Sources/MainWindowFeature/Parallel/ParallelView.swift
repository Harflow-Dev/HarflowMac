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
    var showPrompt: Bool { get }
    var canCancelAll: Bool { get }
    var isEmpty: Bool { get }
    var columns: [ParallelColumnModel] { get }
    var footerText: String { get }
    
    func didAppear()
    func didDisappear()
    func didTapViewPrompt()
    func didTapCancelAll()
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
        VStack(spacing: 0) {
            if viewModel.isEmpty {
                Text("No tasks in this group any more.").font(.pb(.body)).foregroundStyle(Color.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Design point 3: columns fill the available width instead of a fixed 900pt budget —
                // `GeometryReader` reads the row's actual width so `ParallelLayout.columnWidth(memberCount:availableWidth:)`
                // can divide it evenly, keeping the 420pt reading-width floor (and the horizontal scroll) once there
                // are too many members for the window to fit.
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(viewModel.columns) { column in
                                ParallelColumnView(model: column)
                                    .modifier(PanelArrival(animate: column.animatesArrival))
                                    .onAppear(perform: column.onDidPresent)
                                    .frame(
                                        width: ParallelLayout.columnWidth(memberCount: viewModel.columns.count, availableWidth: proxy.size.width),
                                        height: max(0, proxy.size.height)
                                    )
                                Divider()
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(viewModel.footerText).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// The group's header lives in the window's toolbar row, as the task detail's does. On macOS 26
    /// the title sits on the bare toolbar (no glass capsule) and a spacer pushes the actions trailing.
    @ViewBuilder
    private func withToolbar(@ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            content().toolbar {
                ToolbarItem(placement: .navigation) { groupTitle }.sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                // The task screen's quiet buttons, each on the bare toolbar — no glass capsule.
                ToolbarItem(placement: .primaryAction) { viewPromptButton }.sharedBackgroundVisibility(.hidden)
                if viewModel.canCancelAll {
                    ToolbarItem(placement: .primaryAction) { cancelAllButton }.sharedBackgroundVisibility(.hidden)
                }
            }
        } else {
            content().toolbar {
                ToolbarItem(placement: .navigation) { groupTitle }
                ToolbarItemGroup(placement: .primaryAction) { groupActions }
            }
        }
    }

    private var groupTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.groupName).font(.pb(.headline, weight: .semibold)).lineLimit(1)
            Text(viewModel.headerSubtitle).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).lineLimit(1)
        }
    }

    @ViewBuilder
    private var groupActions: some View {
        viewPromptButton
        if viewModel.canCancelAll { cancelAllButton }
    }

    private var viewPromptButton: some View {
        Button("View prompt") { viewModel.didTapViewPrompt() }.buttonStyle(QuietButtonStyle())
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
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 180, height: 18)
                    SkeletonBlock(width: 260, height: 12)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0 ..< columnCount, id: \.self) { _ in
                            columnPlaceholder
                                .frame(
                                    width: ParallelLayout.columnWidth(memberCount: columnCount, availableWidth: proxy.size.width),
                                    height: max(0, proxy.size.height)
                                )
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var columnPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SkeletonBlock(width: 22, height: 22, cornerRadius: 11)
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonBlock(width: 160, height: 14)
                    SkeletonBlock(width: 100, height: 10)
                }
            }
            Divider()
            SkeletonRows(count: 4, showsBadge: false)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

#if DEBUG
#Preview {
    ParallelView(ParallelViewModelMock())
        .frame(width: 900, height: 600)
}
#endif
