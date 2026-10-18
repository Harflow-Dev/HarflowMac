import Foundation
import PbCommon
import PbRepository

// MARK: - SidebarListReconciler

/// Flattening, complete equality and structural diffing run in a detached task.
enum SidebarListReconciler {
    enum Operation: Sendable {
        case remove(Int)
        case insert(Int, SidebarNativeIdentity)
        case move(Int, Int)
    }

    struct Result: Sendable {
        let entries: [SidebarListEntry]
        let changedIDs: Set<SidebarDisplayID>
        var operations: [Operation] = []
        var indexes: [SidebarDisplayID: Int] = [:]
        var entriesByID: [SidebarDisplayID: SidebarListEntry] = [:]
        var logicalDisplays: [String: Set<SidebarDisplayID>] = [:]
        var birthCounter = 0
        var destinations: [MonitorDestination: IndexSet] = [:]
        var quiet = false
        var calculationSeconds: TimeInterval = 0
    }

    static func reconcile(_ input: SidebarListPresentation, previousInput: SidebarListPresentation?,
                          previous: [SidebarListEntry], overlay: [String: SidebarNativeTransition], birthCounter: Int = 0) -> Result? {
        guard !Task.isCancelled else { return nil }
        let started = Date.timeIntervalSinceReferenceDate
        if input == previousInput, overlay.values.allSatisfy({ $0.epoch <= input.transitionEpoch }) {
            return .init(entries: previous, changedIDs: [], birthCounter: birthCounter, quiet: true,
                         calculationSeconds: Date.timeIntervalSinceReferenceDate - started)
        }
        let fading = effectiveFading(input, overlay: overlay)
        var result = flatten(input, previous: previous, excluding: fading)
        guard !Task.isCancelled else { return nil }
        var entries = result.entries
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.displayID, $0) })
        var nextBirth = birthCounter
        let context = TransitionContext(previous: previous, previousByID: previousByID, overlay: overlay,
                                        epoch: input.transitionEpoch, fading: fading)
        guard applyTransitions(entries: &entries, context: context, birthCounter: &nextBirth),
              let operations = nativeOperations(entries: entries, previous: previous) else { return nil }
        var indexes: [SidebarDisplayID: Int] = [:]
        var logicalDisplays: [String: Set<SidebarDisplayID>] = [:]
        var destinations: [MonitorDestination: IndexSet] = [:]
        var changedIDs: Set<SidebarDisplayID> = []
        for (index, entry) in entries.enumerated() {
            indexes[entry.displayID] = index
            logicalDisplays[entry.id, default: []].insert(entry.displayID)
            if let destination = entry.destination { destinations[destination, default: []].insert(index) }
            if previousByID[entry.displayID] != entry { changedIDs.insert(entry.displayID) }
        }
        result = .init(entries: entries,
                       changedIDs: changedIDs, operations: operations, indexes: indexes,
                       entriesByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.displayID, $0) }),
                       logicalDisplays: logicalDisplays, birthCounter: nextBirth, destinations: destinations)
        result.calculationSeconds = Date.timeIntervalSinceReferenceDate - started
        return result
    }

    private struct TransitionContext {
        let previous: [SidebarListEntry]
        let previousByID: [SidebarDisplayID: SidebarListEntry]
        let overlay: [String: SidebarNativeTransition]
        let epoch: Int
        let fading: Set<String>
    }

    private static func effectiveFading(_ input: SidebarListPresentation, overlay: [String: SidebarNativeTransition]) -> Set<String> {
        var fading = input.fadingIDs
        for (id, transition) in overlay where transition.epoch > input.transitionEpoch {
            if transition.fading { fading.insert(id) } else { fading.remove(id) }
        }
        return fading
    }

    private static func applyTransitions(entries: inout [SidebarListEntry], context: TransitionContext,
                                         birthCounter: inout Int) -> Bool {
        entries.removeAll { entry in
            guard let transition = context.overlay[entry.id] else { return false }
            return transition.ended && context.epoch < transition.epoch
        }
        for index in entries.indices {
            guard !Task.isCancelled else { return false }
            if let previous = context.previousByID[entries[index].displayID] {
                entries[index].incarnation = previous.incarnation
            } else {
                birthCounter += 1
                entries[index].incarnation = birthCounter
            }
        }
        return retainFading(entries: &entries, context: context)
    }

    private static func retainFading(entries: inout [SidebarListEntry], context: TransitionContext) -> Bool {
        var sections: [SidebarDisplayID?] = []
        var section: SidebarDisplayID?
        for entry in context.previous {
            if case .heading = entry.content { section = entry.displayID }
            sections.append(section)
        }
        for index in context.previous.indices.reversed() {
            guard !Task.isCancelled else { return false }
            let entry = context.previous[index]
            guard context.fading.contains(entry.id), context.overlay[entry.id]?.ended != true else { continue }
            if let section = sections[index], !entries.contains(where: { $0.displayID == section }),
               let heading = context.previousByID[section] {
                let nextHeading = context.previous.dropFirst(index + 1).first { previous in
                    if case .heading = previous.content { return entries.contains { $0.displayID == previous.displayID } }
                    return false
                }
                let headingInsertion = nextHeading.flatMap { next in entries.firstIndex { $0.displayID == next.displayID } } ?? entries.endIndex
                entries.insert(heading, at: headingInsertion)
            }
            var retained = entry
            retained.isFading = true
            let insertion = retainedInsertion(index: index, section: sections[index], entries: entries, previous: context.previous)
            entries.insert(retained, at: insertion)
        }
        return true
    }

    /// Preserve each outgoing occurrence's old section and successor anchor even if its root moved.
    private static func retainedInsertion(index: Int, section: SidebarDisplayID?, entries: [SidebarListEntry],
                                          previous: [SidebarListEntry]) -> Int {
        let start = section.flatMap { section in entries.firstIndex { $0.displayID == section }.map { $0 + 1 } } ?? 0
        let end = entries[start...].firstIndex {
            if case .heading = $0.content { return true }
            return false
        } ?? entries.endIndex
        let positions = Dictionary(uniqueKeysWithValues: entries[start ..< end].enumerated().map { ($0.element.displayID, start + $0.offset) })
        for following in previous.dropFirst(index + 1) {
            if case .heading = following.content { break }
            if let anchor = positions[following.displayID] { return anchor }
        }
        return end
    }

    private static func nativeOperations(entries: [SidebarListEntry], previous: [SidebarListEntry]) -> [Operation]? {
        var operations: [Operation] = []
        var order = previous.map(\.nativeID)
        let nextIDs = entries.map(\.nativeID)
        let nextSet = Set(nextIDs)
        for index in order.indices.reversed() where !nextSet.contains(order[index]) {
            order.remove(at: index)
            operations.append(.remove(index))
        }
        var positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        for (index, identity) in nextIDs.enumerated() {
            guard !Task.isCancelled else { return nil }
            if index < order.count, order[index] == identity { continue }
            if let source = positions[identity] {
                order.remove(at: source)
                order.insert(identity, at: index)
                operations.append(.move(source, index))
                for changed in min(source, index) ... max(source, index) { positions[order[changed]] = changed }
            } else {
                order.insert(identity, at: index)
                operations.append(.insert(index, identity))
                for changed in index ..< order.count { positions[order[changed]] = changed }
            }
        }
        return operations
    }

    static func reconcile(_ input: SidebarListPresentation, previous: [SidebarListEntry]) -> Result {
        flatten(input, previous: previous, excluding: [])
    }

    private static func flatten(_ input: SidebarListPresentation, previous: [SidebarListEntry], excluding fading: Set<String>) -> Result {
        var entries: [SidebarListEntry] = [
            .init(id: "header:workflows", content: .workflowsHeader(expanded: input.workflowsExpanded))
        ]
        if input.workflowsExpanded {
            entries += input.workflowTitles.map {
                .init(id: "definition:\($0)", content: .workflowDefinition($0), minimumHeight: input.minimumRowHeight)
            }
        }
        if let banner = input.banner {
            entries.append(.init(id: "diagnostic:banner", content: .banner(banner)))
        } else if let error = input.listError {
            entries.append(.init(id: "diagnostic:error", content: .error(error)))
        }
        if input.skeleton {
            entries.append(.init(id: "diagnostic:skeleton", content: .skeleton))
        } else {
            var occurrences: [SidebarDisplayID: Int] = [:]
            for section in input.sections {
                entries.append(.init(id: "header:\(section.id)", content: .heading(section.title)))
                entries += itemEntries(section.items, minimumHeight: input.minimumRowHeight, excluding: fading, occurrences: &occurrences)
            }
            if needsPresentation(input.taskHistory) || needsPresentation(input.workflowHistory) {
                entries.append(.init(id: "header:history", content: .heading("History")))
                if needsPresentation(input.taskHistory) {
                    entries.append(.init(id: "history:tasks", content: .history("Tasks", input.taskHistory), minimumHeight: input.minimumRowHeight))
                }
                if needsPresentation(input.workflowHistory) {
                    entries.append(.init(id: "history:workflows", content: .history("Workflows", input.workflowHistory), minimumHeight: input.minimumRowHeight))
                }
            }
            if let message = input.emptyMessage {
                entries.append(.init(id: "diagnostic:empty", content: .empty(message)))
            }
            entries.append(.init(id: "history:sentinel", content: .sentinel))
        }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.displayID, $0) })
        return Result(entries: entries,
                      changedIDs: Set(entries.filter { old[$0.displayID] != $0 }.map(\.displayID)))
    }

    private static func itemEntries(_ items: [SidebarItem], minimumHeight: Double, excluding fading: Set<String>,
                                    occurrences: inout [SidebarDisplayID: Int]) -> [SidebarListEntry] {
        var owner: String?
        return items.compactMap { item in
            guard !fading.contains(item.id) else { return nil }
            let root: Bool = switch item {
            case .group: true
            case .task(let row), .workflow(let row): row.indent == 0
            case .workflowShortcut: false
            }
            if root { owner = item.id }
            let base = SidebarDisplayID(logicalID: item.id, ownerID: root ? nil : owner ?? SidebarDisplayID.orphanOwnerID)
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            var identity = base
            identity.occurrence = occurrence
            return .init(id: item.id, content: .item(item), minimumHeight: minimumHeight, displayID: identity)
        }
    }

    private static func needsPresentation(_ state: HistoryLoadingState) -> Bool {
        state.catalogState.status == .blocked || state.authorityIncomplete || state.historyIncomplete
            || state.isLoading || state.error != nil || state.bootstrapPending || state.hasMore
    }
}
