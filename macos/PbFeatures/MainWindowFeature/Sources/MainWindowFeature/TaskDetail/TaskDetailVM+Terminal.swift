//
//  TaskDetailVM+Terminal.swift
//  MainWindowFeature
//
//  Tab list/auto-select and the terminal-tab actions (`TaskDetailView.swift:83,85,222-225`,
//  `TerminalPane.swift`). `TerminalPaneView` observes the live `TerminalSession` itself for its
//  status texts (pid/size/ended/terminating/attachError are `@Published`), so the VM only tracks
//  which session (if any) belongs to this task and dispatches the two actions.
//

import Foundation
import MonitorCore
import PbCommon
import PbTerminal

extension TaskDetailVM {
    
    /// The Terminal tab exists only while there is a session (ended or not), inserted at index 2
    /// (F4-37), and is auto-selected whenever a *new* session id appears — matching
    /// `.onChange(of: session?.id)`'s "fires on every change, guarded to non-nil" behaviour, not
    /// merely "the first time a session ever appears". Crucially, `.onChange(of:)` never fires for
    /// its INITIAL value either: revisiting a task that already has a session (item 5) must start on
    /// Timeline, so the very first call here only seeds `lastSessionID` and never switches tabs.
    func recomputeTabs(task: TaskInfo, session: TerminalSession?) {
        var tabs: [TaskTab] = [.timeline, .changes, .prompt, .raw]
        if session != nil { tabs.insert(.terminal, at: 2) }
        self.tabs = tabs
        
        let newSessionID = session?.id
        guard hasObservedInitialSessionID else {
            hasObservedInitialSessionID = true
            lastSessionID = newSessionID
            return
        }
        if newSessionID != lastSessionID {
            lastSessionID = newSessionID
            if newSessionID != nil { tab = .terminal }
        }
    }
    
    func didSelectTakeoverDestination(_ destination: TakeoverDestination) {
        guard let task else { return }
        let isRunning = task.status.isRunning
        let title = isRunning ? "Take over this task?" : "Continue this session in a terminal?"
        let buttonTitle = isRunning ? "Stop it and take over" : "Continue in terminal"
        var message = isRunning
        ? "The headless run is stopped first (with any sub-tasks), then the same conversation opens in a terminal. "
        : "The same conversation opens in a terminal. "
        message += "It runs under your own default permissions, not this task's \(task.freedom ?? "freedom") level. "
        + "While the terminal is open, polybridge refuses resumes of this session from anywhere else."
        publishDialog(title, description: message) {
            AlertAction(title: buttonTitle) { [weak self] in
                guard let self else { return }
                useCase.beginTakeover(taskID: taskID, destination: destination)
            }
            AlertAction(title: "Cancel", role: .cancel)
        }
    }
    
    func didTapEndSession() {
        terminalSession?.terminate()
    }
    
    func didTapCloseSession() {
        guard let session = terminalSession else { return }
        useCase.removeSession(session)
    }
}
