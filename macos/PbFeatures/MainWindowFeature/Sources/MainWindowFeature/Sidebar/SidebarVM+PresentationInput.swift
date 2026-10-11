//
//  SidebarVM+PresentationInput.swift
//  MainWindowFeature
//
//  Split out of SidebarVM.swift purely to keep that file under the swiftlint length budget — same
//  VM, same behaviour. The two pure input builders for the off-main presentation worker:
//  `presentationInput()` captures the immutable snapshot the worker consumes, and
//  `capturedTitles()` resolves the listing's titles at capture time.
//

import Foundation

// MARK: - SidebarVM

extension SidebarVM {
    func presentationInput() -> SidebarPresentationInput {
        SidebarPresentationInput(tasks: latestTasks, runs: workflowRuns, definitions: workflowDefinitions,
            titles: capturedTitles(), catalog: latestCatalog, search: searchQuery, backend: selectedBackend,
            collapsed: collapsedTaskIDs, expanded: expandedExecutionParents, selection: desiredSelection,
            siblings: lastKnownSiblingsByMember, reveal: pendingRevealToApply, workflowReveal: pendingWorkflowRevealID,
            now: currentDate(), calendar: Calendar.current)
    }

    func capturedTitles() -> [String: String] {
        Dictionary(latestTasks.map { ($0.taskID, latestTitles[$0.taskID] ?? useCase.title($0.taskID)) }, uniquingKeysWith: { _, new in new })
    }
}
