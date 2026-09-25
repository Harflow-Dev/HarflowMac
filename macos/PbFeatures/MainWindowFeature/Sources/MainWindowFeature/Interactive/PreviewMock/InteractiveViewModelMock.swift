//
//  InteractiveViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import PbCommon
import PbTerminal

// MARK: - InteractiveViewModelMock

/// Preview mock for `InteractiveView`. `session` defaults to `nil` — the "closed" state — since a
/// real `TerminalSession` constructs a live `LocalProcessTerminalView` internally, which previews
/// must never do (the same reason `TerminalPaneView` itself has no `#Preview`).
@MainActor
final class InteractiveViewModelMock: InteractiveViewModel {
    
    var session: TerminalSession?
    
    init(session: TerminalSession? = nil) {
        self.session = session
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didTapEndSession() {}
    func didTapCloseSession() {}
}

#endif
