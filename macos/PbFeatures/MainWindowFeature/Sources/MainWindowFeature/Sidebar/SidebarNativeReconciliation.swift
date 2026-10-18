import AppKit
import PbCommon
import PbUI
import SwiftUI

// MARK: - Native reconciliation

extension SidebarNativeList.Coordinator {
    func transition(ids: Set<String>, restored: Set<String>, epoch: Int, ended: Bool) {
        guard !ids.isEmpty || !restored.isEmpty else { return }
        appliedRevision += 1
        detached?.cancel()
        reconciliation?.cancel()
        detached = nil
        reconciliation = nil
        pendingInput = input
        beginNativeOperation()
        applyingStructure = true
        defer {
            applyingStructure = false
            endNativeOperation(flushHostedHeights: true)
            startReconciliation()
        }
        for id in ids.union(restored) {
            overlay[id] = .init(epoch: epoch, fading: !restored.contains(id), ended: ended && ids.contains(id))
            for displayID in logicalDisplays[id] ?? [] {
                guard let box = boxesByID[displayID], !ended else { continue }
                let oldDestination = box.entry.destination
                box.entry.isFading = !restored.contains(id)
                box.entryRevision += 1
                if let index = indexesByID[displayID] {
                    if let oldDestination { destinationIndexes[oldDestination]?.remove(index) }
                    if let destination = box.entry.destination { destinationIndexes[destination, default: []].insert(index) }
                }
                refresh(box)
            }
        }
        if ended { removeEndedRows(ids) }
        synchronizeSelection()
    }

    func removeEndedRows(_ ids: Set<String>) {
        if let outline {
            let displays = ids.reduce(into: Set<SidebarDisplayID>()) { $0.formUnion(logicalDisplays[$1] ?? []) }
            let removed = displays.compactMap { indexesByID[$0] }.sorted(by: >)
            if !removed.isEmpty {
                outline.beginUpdates()
                for index in removed {
                    let box = boxes.remove(at: index)
                    lastHostedSelectedIDs.remove(box.entry.displayID)
                    disassociate(box)
                    boxesByID.removeValue(forKey: box.entry.displayID)
                    nativeOperationCount += 1
                    outline.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
                    appliedEntries.remove(at: index)
                }
                outline.endUpdates()
                indexesByID.removeAll(keepingCapacity: true)
                logicalDisplays.removeAll(keepingCapacity: true)
                destinationIndexes.removeAll(keepingCapacity: true)
                for (index, box) in boxes.enumerated() {
                    indexesByID[box.entry.displayID] = index
                    logicalDisplays[box.entry.id, default: []].insert(box.entry.displayID)
                    if let destination = box.entry.destination { destinationIndexes[destination, default: []].insert(index) }
                }
            }
        }
    }

    func startReconciliation() {
        guard reconciliation == nil, let presentation = pendingInput else { return }
        pendingInput = nil
        let base = appliedRevision
        let previous = appliedEntries
        let previousInput = appliedInput
        let overlay = overlay
        let birthCounter = birthCounter
        let barrier = reconciliationBarrier
        reconciliationCount += 1
        let worker = Task.detached(priority: .userInitiated) {
            if let barrier { await barrier() }
            return SidebarListReconciler.reconcile(presentation, previousInput: previousInput,
                                                   previous: previous, overlay: overlay, birthCounter: birthCounter)
        }
        detached = worker
        reconciliation = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            reconciliation = nil
            detached = nil
            if let result, appliedRevision == base {
                offMainCalculationSeconds += result.calculationSeconds
                let started = Date.timeIntervalSinceReferenceDate
                apply(result, generation: generation)
                mainApplySeconds += Date.timeIntervalSinceReferenceDate - started
                self.birthCounter = max(self.birthCounter, result.birthCounter)
                appliedInput = presentation
                if !result.quiet {
                    appliedEntries = result.entries
                    appliedRevision += 1
                    // Ended tombstones retain the next incarnation after structural removal.
                    self.overlay = self.overlay.filter {
                        $0.value.epoch > presentation.transitionEpoch
                            || ($0.value.ended && result.logicalDisplays[$0.key]?.isEmpty == false)
                    }
                    queueGeometry()
                }
            } else {
                rejectedResultCount += 1
                if pendingInput == nil { pendingInput = input }
            }
            startReconciliation()
        }
    }

    func apply(_ result: SidebarListReconciler.Result, generation: Int) {
        guard let outline else { return }
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: true) }
        applyingStructure = true
        defer { applyingStructure = false }
        if result.quiet { return }
        for id in result.changedIDs {
            guard let entry = result.entriesByID[id] else { continue }
            let existing = boxesByID[entry.displayID]
            clearHostedSelectionForNewBirth(entry, existing: existing)
            let box = existing?.entry.nativeID == entry.nativeID ? existing! : SidebarNativeItemBox(entry)
            box.entry = entry
            box.entryRevision += 1
            box.naturalHeight = nil
            boxesByID[entry.displayID] = box
        }
        if !result.operations.isEmpty {
            outline.beginUpdates()
            for operation in result.operations {
                nativeOperationCount += 1
                switch operation {
                case .remove(let index):
                    let removed = boxes.remove(at: index)
                    lastHostedSelectedIDs.remove(removed.entry.displayID)
                    disassociate(removed)
                    if boxesByID[removed.entry.displayID] === removed { boxesByID.removeValue(forKey: removed.entry.displayID) }
                    outline.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
                case .move(let source, let index):
                    let box = boxes.remove(at: source)
                    boxes.insert(box, at: index)
                    outline.moveItem(at: source, inParent: nil, to: index, inParent: nil)
                case .insert(let index, let identity):
                    guard let box = boxesByID[identity.displayID], box.entry.nativeID == identity else { preconditionFailure("Missing native identity") }
                    boxes.insert(box, at: index)
                    outline.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
                }
            }
            outline.endUpdates()
        }
        indexesByID = result.indexes
        logicalDisplays = result.logicalDisplays
        destinationIndexes = result.destinations
        for id in result.changedIDs { if let box = boxesByID[id] { refresh(box) } }
        applyingStructure = false
        settledGeneration = generation
        synchronizeSelection()
        queueGeometry()
    }

    private func clearHostedSelectionForNewBirth(_ entry: SidebarListEntry, existing: SidebarNativeItemBox?) {
        if existing?.entry.nativeID != entry.nativeID {
            lastHostedSelectedIDs.remove(entry.displayID)
        }
    }

}
