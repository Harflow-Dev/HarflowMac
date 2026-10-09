import Foundation
import MonitorCore
import PbCommon
import PbRepository
import PbUI

// MARK: - SidebarPresentationInput

/// Value snapshot captured before leaving the main actor.
struct SidebarPresentationInput: Sendable, Equatable {
    let tasks: [TaskInfo]
    let runs: [SidebarWorkflowRun]
    let definitions: [WorkflowRecord]
    let titles: [String: String]
    let catalog: BackendCatalog
    let search: String
    let backend: String
    let collapsed: Set<String>
    let expanded: Set<String>
    let selection: MonitorDestination?
    let siblings: [String: Set<String>]
    let reveal: PendingReveal?
    let workflowReveal: String?
    let now: Date
    let calendar: Calendar
    func hasSameSources(as other: Self) -> Bool {
        tasks == other.tasks && runs == other.runs && definitions == other.definitions && titles == other.titles
            && catalog == other.catalog && search == other.search && backend == other.backend
            && collapsed == other.collapsed && expanded == other.expanded && selection == other.selection
            && siblings == other.siblings && reveal == other.reveal && workflowReveal == other.workflowReveal && calendar == other.calendar
    }

}

// MARK: - SidebarPresentation

struct SidebarPresentation: Sendable, Equatable {
    let sections: [SidebarSection]
    let savedWorkflows: [WorkflowRecord]
    let backendTabs: [BackendTab]
    let catalogUnavailableNote: String?
    let selectedBackend: String
    let selection: MonitorDestination?
}

// MARK: - SidebarPresentationBuild

/// Internal indexes are returned separately from rendering state for interaction handling.
struct SidebarPresentationBuild: Sendable {
    let presentation: SidebarPresentation
    let conversationIndex: ConversationIndex
    let owners: [String: String]
    let children: [String: [TaskInfo]]
    let collapsed: Set<String>
    let expanded: Set<String>
    let siblings: [String: Set<String>]
    let consumedReveal: UUID?
    let remainingWorkflowReveal: String?
    let representatives: [String: String]
    let executionParents: [String: String]
    let groups: [String: [Conversation]]
}

// MARK: - SidebarPresentationBuilder

/// Pure value computation; no UI actor, repositories, routing or mutable VM is captured.
struct SidebarPresentationBuilder: Sendable {
    let input: SidebarPresentationInput
    let latestTasks: [TaskInfo]
    var workflowRuns: [SidebarWorkflowRun] { input.runs }
    var workflowDefinitions: [WorkflowRecord] { input.definitions }
    var latestCatalog: BackendCatalog { input.catalog }
    var searchQuery: String { input.search }
    var selectedBackend: String
    var selection: MonitorDestination?
    var collapsedTaskIDs: Set<String>
    var expandedExecutionParents: Set<String>
    var lastKnownSiblingsByMember: [String: Set<String>]
    var conversationIndex: ConversationIndex
    var backendTabs: [BackendTab] = []
    var catalogUnavailableNote: String?
    var indexedOwners: [String: String] = [:]
    var indexedChildren: [String: [TaskInfo]] = [:]
    var indexedRuns: [String: SidebarWorkflowRun] = [:]
    var visibleRuns: [SidebarWorkflowRun] = []
    var visibleChildren: [String: [SidebarWorkflowRun]] = [:]
    var transportIDs: Set<String> = []
    var indexedLabels: [String: String] = [:]
    var representatives: [String: String] = [:]
    var executionParents: [String: String] = [:]
    var indexedGroupConversations: [String: [Conversation]] = [:]
    var unfilteredChildRuns: Set<String> = []
    var consumedReveal: UUID?
    var remainingWorkflowReveal: String?

    static func compute(_ input: SidebarPresentationInput) -> SidebarPresentationBuild? {
        let start = MonitorMetrics.begin()
        defer { MonitorMetrics.end(start, stage: .sidebarBuild, backgroundThread: !Thread.isMainThread) }
        var builder = Self(input: input)
        return try? builder.build()
    }

    init(input: SidebarPresentationInput) {
        self.input = input
        self.latestTasks = input.tasks.filter { $0.raw["workflow_builder"]?.boolValue != true }
        self.selectedBackend = input.backend
        self.selection = input.selection
        self.collapsedTaskIDs = input.collapsed
        self.expandedExecutionParents = input.expanded
        self.lastKnownSiblingsByMember = input.siblings
        self.conversationIndex = ConversationIndex(latestTasks)
        self.remainingWorkflowReveal = input.workflowReveal
    }

    func title(_ id: String) -> String { input.titles[id] ?? "Task \(id.prefix(8))" }

    mutating func build() throws -> SidebarPresentationBuild {
        try Task.checkCancellation()
        try prepareIndexes()
        applyReveals()
        recomputeBackendTabs()
        migrateCollapsedIDsForRetention()
        selection = normalized(selection)
        visibleRuns = computeFilteredWorkflowRuns()
        visibleChildren = Dictionary(grouping: visibleRuns.filter { $0.parentRunID != nil }, by: { $0.parentRunID! })
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let backend = selectedBackend
        let builderIDs = Set(indexedOwners.keys)
        func matches(_ task: TaskInfo) -> Bool {
            !WorkflowNodePresentation.isNativeControl(task) && !builderIDs.contains(task.taskID)
                && (backend == "all" || task.backend == backend)
                && (query.isEmpty || title(task.taskID).lowercased().contains(query)
                    || task.taskID.lowercased().contains(query) || task.repoPath.lowercased().contains(query))
        }
        let matched = conversationIndex.sections(matches: matches)
        recordMembership(conversationIndex.sections())
        let forced: Set<String> = !query.isEmpty || backend != "all"
            ? Set(latestTasks.filter(matches).flatMap { conversationIndex.ancestors(ofConversationContaining: $0.taskID).map(\.id) }) : []
        try Task.checkCancellation()
        let sections = bucketedSections(trees: matched.running + matched.recent,
            groups: latestTasks.contains { $0.group != nil } ? Lineage.sections(latestTasks, matches: matches).parallel : [], forcedExpandedIDs: forced)
        try Task.checkCancellation()
        return SidebarPresentationBuild(presentation: SidebarPresentation(sections: sections, savedWorkflows: savedWorkflows,
            backendTabs: backendTabs, catalogUnavailableNote: catalogUnavailableNote, selectedBackend: selectedBackend, selection: selection),
            conversationIndex: conversationIndex, owners: indexedOwners, children: indexedChildren,
            collapsed: collapsedTaskIDs, expanded: expandedExecutionParents, siblings: lastKnownSiblingsByMember,
            consumedReveal: consumedReveal, remainingWorkflowReveal: remainingWorkflowReveal,
            representatives: representatives, executionParents: executionParents, groups: indexedGroupConversations)
    }

    mutating func prepareIndexes() throws {
        indexedRuns = Dictionary(workflowRuns.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        indexedOwners = computeWorkflowTaskOwners()
        unfilteredChildRuns = Set(workflowRuns.compactMap(\.parentRunID))
        executionParents = indexedOwners.mapValues { "workflow:\($0)" }
        try prepareLabels()
        transportIDs = Set(workflowRuns.flatMap { WorkflowJSON.objects($0.raw["activations"]) }
            .filter { $0["role"]?.stringValue == "native_control" }
            .flatMap { WorkflowJSON.objects($0["tasks"]).compactMap { $0["task_id"]?.stringValue } })
        let grouped = Dictionary(grouping: latestTasks.filter {
            indexedOwners[$0.taskID] != nil && !WorkflowNodePresentation.isNativeControl($0) && !transportIDs.contains($0.taskID)
        }, by: { indexedOwners[$0.taskID]! })
        for (id, tasks) in grouped {
            try Task.checkCancellation()
            indexedChildren[id] = SidebarConversationGrouping(tasks.sorted(by: executionOrder), fallbackToConversation: false)
.conversations
                .compactMap { WorkflowOrchestratorConversation.representative($0.members) }
.sorted(by: executionOrder)
        }
        representatives = SidebarConversationGrouping(latestTasks, fallbackToConversation: false)
.membersByTask
            .compactMapValues { $0.first?.taskID }
        if latestTasks.contains(where: { $0.group != nil }) {
            for group in Lineage.sections(latestTasks).parallel {
                indexedGroupConversations[group.id] = groupConversations(group)
                guard (indexedGroupConversations[group.id]?.count ?? 0) > 1 else { continue }
                for task in groupChildren(group.name) { executionParents[task.taskID] = group.id }
            }
        }
    }

    mutating func applyReveals() {
        if let reveal = input.reveal, latestTasks.contains(where: { $0.taskID == reveal.taskID }) {
            expandExecutionParent(of: reveal.taskID)
            for ancestor in conversationIndex.ancestors(ofConversationContaining: reveal.taskID) { collapsedTaskIDs.remove(ancestor.id) }
            consumedReveal = reveal.requestID
        }
        if let revealID = remainingWorkflowReveal {
            var current = revealID
            var visited: Set<String> = []
            while visited.insert(current).inserted, let run = indexedRuns[current] {
                guard let parent = run.parentRunID else { remainingWorkflowReveal = nil; break }
                expandedExecutionParents.insert("workflow:\(parent)")
                current = parent
            }
            if visited.contains(current), indexedRuns[current] != nil { remainingWorkflowReveal = nil }
        }
    }

    mutating func prepareLabels() throws {
        for run in workflowRuns {
            try Task.checkCancellation()
            let labels = Dictionary(WorkflowJSON.nodes(run.raw["definition"]?.objectValue ?? [:]).map { ($0.id, $0.name) }, uniquingKeysWith: { _, new in new })
            for activation in WorkflowJSON.objects(run.raw["activations"]) {
                let nodeID = activation["node_id"]?.stringValue
                let label = activation["role"]?.stringValue == "orchestrator" ? "Orchestrator"
                    : nodeID.map { run.raw["node_labels"]?[$0]?.stringValue ?? labels[$0] ?? $0 }
                for task in WorkflowJSON.objects(activation["tasks"]) {
                    if let id = task["task_id"]?.stringValue, let label, indexedLabels[id] == nil { indexedLabels[id] = label }
                }
            }
        }
    }

}
