import MonitorCore

// MARK: - Main-pane gates

extension MainWindowCoordinator {
    /// Whether work can be created and navigated: the runtime is ready and no main-pane gate shows.
    public var workIsAvailable: Bool { runtimeIsReady && mainGate == nil }

    /// Writes the gate only when it changes, so a repeated listing failure does not republish.
    func refreshMainGate() {
        let gate = MainWindowGate.classify(runtimeReady: runtimeIsReady, listError: latestListError)
        guard mainGate != gate else { return }
        mainGate = gate
        // A runner left open when the gate arrives would let a launch through.
        if gate != nil, presentedSheet == .workflowRunner { presentedSheet = nil }
    }
}
