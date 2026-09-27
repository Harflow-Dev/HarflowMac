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
            realContent
                .onAppear { viewModel.didAppear() }
                .onDisappear { viewModel.didDisappear() }
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var realContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isEmpty {
                Text("No tasks in this group any more.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Design point 3: columns fill the available width instead of a fixed 900pt budget —
                // `GeometryReader` reads the row's actual width so `ParallelLayout.columnWidth(memberCount:availableWidth:)`
                // can divide it evenly, keeping the 360pt floor (and the horizontal scroll) once there
                // are too many members for the window to fit.
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(viewModel.columns) { column in
                                ParallelColumnView(model: column)
                                    .frame(width: ParallelLayout.columnWidth(memberCount: viewModel.columns.count, availableWidth: proxy.size.width))
                                Divider()
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(viewModel.footerText).font(.pb(.secondary)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.groupName).font(.pb(.title, weight: .semibold))
                Text(viewModel.headerSubtitle).font(.pb(.secondary)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("View prompt") { viewModel.didTapViewPrompt() }
            if viewModel.canCancelAll {
                Button("Cancel all", role: .destructive) { viewModel.didTapCancelAll() }
            }
        }
        .padding(14)
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
            .padding(14)
            Divider()
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0 ..< columnCount, id: \.self) { _ in
                            columnPlaceholder
                                .frame(width: ParallelLayout.columnWidth(memberCount: columnCount, availableWidth: proxy.size.width))
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
                Circle().fill(Color.primary.opacity(0.1)).frame(width: 22, height: 22).shimmering()
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonBlock(width: 160, height: 14)
                    SkeletonBlock(width: 100, height: 10)
                }
            }
            Divider()
            SkeletonRows(count: 4, showsBadge: false)
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

#if DEBUG
#Preview {
    ParallelView(ParallelViewModelMock())
        .frame(width: 900, height: 600)
}
#endif
