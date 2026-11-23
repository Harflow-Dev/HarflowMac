import AppKit

// MARK: - NewSessionRouting

extension MainWindowCoordinator: NewSessionRouting {
    /// `NSOpenPanel` is AppKit, which is allowed here (the coordinator, in the feature layer) —
    /// just not in `NewSessionVM`, which only calls `routing.chooseDirectory()` and awaits the
    /// result. Modal, exactly like the old `NewSessionSheet.choose()`.
    public func chooseDirectory() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
    
    public func didStart(taskID: String) {
        selection = .task(taskID)
    }

    public func reviewRecent() {
        // Only navigate to a task actually observed through the public listing.
        if let task = taskListRepository.tasks.max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
            selectTask(task.taskID)
        }
        sharedSidebarVM().didTapLoadMoreTasks()
    }

    public func dismiss() {
        isNewSessionPresented = false
    }
}
