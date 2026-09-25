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
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.groupName).font(.system(size: 16, weight: .semibold))
                    Text(viewModel.headerSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("View prompt") { viewModel.didTapViewPrompt() }
                if viewModel.canCancelAll {
                    Button("Cancel all", role: .destructive) { viewModel.didTapCancelAll() }
                }
            }
            .padding(14)
            Divider()
            if viewModel.isEmpty {
                Text("No tasks in this group any more.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(viewModel.columns) { column in
                            ParallelColumnView(model: column)
                                .frame(width: ParallelLayout.columnWidth(memberCount: viewModel.columns.count))
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(viewModel.footerText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
#Preview {
    ParallelView(ParallelViewModelMock())
        .frame(width: 900, height: 600)
}
#endif
