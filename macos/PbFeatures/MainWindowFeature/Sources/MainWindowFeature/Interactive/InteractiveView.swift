//
//  InteractiveView.swift
//  MainWindowFeature
//
//  Ported from the app target's `MainView.swift`'s `InteractiveView`/`.interactive(let id)` case.
//  Behaviour is unchanged: the header shows the session's backend badge and title, the pane below is
//  the same `TerminalPaneView` component TaskDetail's Terminal tab uses, and a missing or closed
//  session (never started, or already removed) shows the exact "This terminal has closed." state the
//  old `MainView.swift` fell back to.
//

import PbCommon
import PbTerminal
import PbUI
import SwiftUI

// MARK: - InteractiveViewModel

/// View model protocol for the interactive-terminal screen.
@MainActor
protocol InteractiveViewModel: ViewModel {
    
    /// The live session for this screen's `sessionID`, or `nil` when it has never existed or was
    /// removed ("Close"). `title`/`backend` are read directly off the session (plain, non-`@Published`
    /// properties on `TerminalSession`), and `TerminalPaneView` observes the session itself for its
    /// own live status text.
    var session: TerminalSession? { get }
    
    func didAppear()
    func didDisappear()
    func didTapEndSession()
    func didTapCloseSession()
}

// MARK: - InteractiveView

struct InteractiveView<VM: InteractiveViewModel>: View {
    
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
        Group {
            if let session = viewModel.session {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        BackendBadge(backend: session.backend, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).font(.system(size: 16, weight: .semibold))
                            Text("Interactive session started from the Monitor · not a polybridge task, so it is not tracked or reserved")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    Divider()
                    TerminalPaneView(session: session, onEndSession: { viewModel.didTapEndSession() }, onClose: { viewModel.didTapCloseSession() })
                }
            } else {
                Text("This terminal has closed.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
#Preview {
    InteractiveView(InteractiveViewModelMock())
        .frame(width: 700, height: 500)
}
#endif
