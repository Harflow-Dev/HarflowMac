//
//  MainWindowCoordinator+TopBar.swift
//  MainWindowFeature
//
//  The top bar's slot state for a selected task before its view has mounted and published. The coordinator derives
//  it from the listing and writes it to the holder; only the principal reads it, so the shell never does.
//

import Foundation
import MonitorCore

// MARK: - MainWindowCoordinator + task top bar pre-mount state

extension MainWindowCoordinator {
    /// What the task slot shows before a mounted task view has published, for the current selection and listing:
    /// loading with the title the listing knows (the same first-member rule the loaded bar uses), loading without a
    /// title while the listing has not been read, `nil` (the caption) for any other selection, while the runtime is
    /// not ready, and for a task the read listing does not hold.
    func taskTopBarPreMountSlot() -> TaskTopBarSlot? {
        guard runtimeIsReady, case .task(let id) = selection else { return nil }
        let listing = taskListRepository
        let tasks = listing.tasks
        if let requested = tasks.first(where: { $0.taskID == id }), TaskDetailVM.isWorkflowExecutionChild(requested) {
            return .loading(title: listing.title(requested.taskID))
        }
        let key = normalisedConversationID(for: id)
        if tasks.contains(where: { $0.taskID == key }) { return .loading(title: listing.title(key)) }
        return listing.hasListed ? nil : .loading(title: nil)
    }

    /// Writes the pre-mount slot state to the holder; the holder drops a repeated value.
    func refreshTaskTopBarPreMount() {
        topBar.setPreMountSlot(taskTopBarPreMountSlot())
    }

    /// The selection changed: the top bar follows its subject and the pre-mount slot state is derived again.
    func selectionChangedTopBar() {
        topBar.setShownSubject(shownTopBarSubject())
        refreshTaskTopBarPreMount()
    }

    func publishTopBarSlot(_ slot: TaskTopBarSlot, tag: TaskTopBarHolder.Tag) { topBar.publish(slot: slot, tag: tag) }
}
