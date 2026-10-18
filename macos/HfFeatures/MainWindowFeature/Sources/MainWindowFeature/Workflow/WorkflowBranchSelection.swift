import MonitorCore

// MARK: - WorkflowGroupInvocation

/// Immutable presentation of one group's persisted membership, never inferred from tasks.
struct WorkflowGroupInvocation: Identifiable, Equatable {
    let id: String
    let raw: [String: JSONValue]
    let isReleased: Bool
    var splitID: String { raw["split_id"]?.stringValue ?? "" }
    var sequence: Int { raw["selection_sequence"]?.intValue ?? 0 }
    var selectedConnectionIDs: Set<String> { Set(raw["selected_connection_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []) }
    var excludedConnectionIDs: Set<String> { Set(raw["excluded_connection_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []) }
    var hasSelection: Bool { raw["selected_connection_ids"]?.arrayValue != nil }
    var reason: String { raw["selection_reason"]?.stringValue ?? "" }
    var ancestorIDs: [String] { raw["stack"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var resolvedCount: Int { raw["arrival_ids"]?.arrayValue?.count ?? (isReleased ? raw["expected"]?.intValue ?? 0 : 0) }
    var expectedCount: Int { raw["expected"]?.intValue ?? selectedConnectionIDs.count }

    static func history(in run: WorkflowRunModel, splitID: String? = nil) -> [Self] {
        var result: [String: Self] = [:]
        for key in ["released_parallel_groups", "joins"] {
            for (id, value) in run.raw[key]?.objectValue ?? [:] {
                guard let raw = value.objectValue, splitID == nil || raw["split_id"]?.stringValue == splitID else { continue }
                result[id] = Self(id: id, raw: raw, isReleased: key != "joins")
            }
        }
        return result.values.sorted {
            if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
            if $0.isReleased != $1.isReleased { return !$0.isReleased }
            return $0.id < $1.id
        }
    }
}

// MARK: - WorkflowBranchSelection

struct WorkflowBranchSelection: Equatable {
    var excludedNodeIDs: Set<String> = []
    var excludedEdgeIDs: Set<String> = []
    var selectedEdgeIDs: Set<String> = []
    var nodeGenerationIDs: [String: Set<String>] = [:]

    static func build(run: WorkflowRunModel) -> Self {
        let nodes = WorkflowJSON.nodes(run.definition)
        let edges = WorkflowJSON.edges(run.definition)
        let history = WorkflowGroupInvocation.history(in: run)
        var latest: [String: WorkflowGroupInvocation] = [:]
        for generation in history where latest[generation.splitID] == nil { latest[generation.splitID] = generation }
        let latestIDs = Set(latest.values.map(\.id))
        let knownIDs = Set(history.map(\.id))
        var result = Self()
        for generation in latest.values {
            // An old nested selection does not describe a newly re-entered outer group.
            guard generation.ancestorIDs.allSatisfy({ !knownIDs.contains($0) || latestIDs.contains($0) }),
                  generation.hasSelection,
                  let split = nodes.first(where: { $0.id == generation.splitID }),
                  let end = WorkflowParallelGroup.partner(of: split, nodes: nodes) else { continue }
            let entries = edges.filter { $0.source == split.id && !$0.isBackward }
            var chosenNodes: Set<String> = []
            var ignoredNodes: Set<String> = []
            var chosenEdges: Set<String> = []
            var ignoredEdges: Set<String> = []
            for edge in entries {
                let region = branch(from: edge.target, stoppingAt: end.id, edges: edges)
                if generation.selectedConnectionIDs.contains(edge.id) {
                    chosenNodes.formUnion(region.nodes)
                    chosenEdges.formUnion(region.edges.union([edge.id]))
                } else if generation.excludedConnectionIDs.contains(edge.id) {
                    ignoredNodes.formUnion(region.nodes)
                    ignoredEdges.formUnion(region.edges.union([edge.id]))
                }
            }
            ignoredNodes.subtract(chosenNodes)
            ignoredEdges.subtract(chosenEdges)
            result.excludedNodeIDs.formUnion(ignoredNodes)
            result.excludedEdgeIDs.formUnion(ignoredEdges)
            result.selectedEdgeIDs.formUnion(chosenEdges)
            for id in chosenNodes { result.nodeGenerationIDs[id, default: []].insert(generation.id) }
        }
        result.selectedEdgeIDs.subtract(result.excludedEdgeIDs)
        return result
    }

    private static func branch(from entry: String, stoppingAt end: String, edges: [WorkflowEdgeModel]) -> (nodes: Set<String>, edges: Set<String>) {
        var nodes: Set<String> = []
        var connectionIDs: Set<String> = []
        var queue = [entry]
        while let id = queue.popLast() {
            guard id != end, nodes.insert(id).inserted else { continue }
            for edge in edges where edge.source == id && !edge.isBackward {
                connectionIDs.insert(edge.id)
                if edge.target != end { queue.append(edge.target) }
            }
        }
        return (nodes, connectionIDs)
    }

    func includes(_ activation: [String: JSONValue], nodeID: String) -> Bool {
        guard let generations = nodeGenerationIDs[nodeID], !generations.isEmpty else { return true }
        let branchIDs = activation["token"]?["branch_ids"]?.objectValue ?? [:]
        return generations.allSatisfy { branchIDs[$0] != nil }
    }
}

// MARK: - WorkflowVM Branch selection

extension WorkflowVM {
    func updateBranchSelection() {
        branchSelection = selectedRun.map(WorkflowBranchSelection.build) ?? WorkflowBranchSelection()
    }
}
