@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowClipboardTests

struct WorkflowClipboardTests {
    private func node(_ id: String, type: String = "agent", x: Double = 0) -> JSONValue {
        .object(["id": .string(id), "type": .string(type), "position": .object(["x": .number(x), "y": .number(0)]),
                 "instructions": .string("Keep these instructions")])
    }

    @Test func givenSelectedPair_whenPasted_thenInternalEdgeAndFreshIDsPreserveContent() throws {
        // given
        let definition: [String: JSONValue] = ["nodes": .array([node("a"), node("b", x: 300), node("c", x: 600)]), "connections": .array([
            .object(["id": .string("ab"), "source": .string("a"), "target": .string("b"), "condition": .string("approved")]),
            .object(["id": .string("bc"), "source": .string("b"), "target": .string("c")])
        ])]
        let payload = try #require(WorkflowClipboard.payload(definition: definition, selection: ["a", "b"]))
        // when
        let result = try #require(WorkflowClipboard.pasted(payload, into: definition))
        // then
        #expect(result.ids.count == 2)
        #expect(result.ids.isDisjoint(with: ["a", "b", "c"]))
        let edges = WorkflowJSON.edges(result.definition)
        #expect(edges.count == 3)
        #expect(result.ids.contains(edges[2].source) && result.ids.contains(edges[2].target))
        #expect(edges[2].condition == "approved")
        #expect(WorkflowJSON.nodes(result.definition).suffix(2).allSatisfy { $0.instructions == "Keep these instructions" })
    }

    @Test func givenExistingTerminals_whenPasted_thenDuplicatesAndTheirEdgesAreSkipped() throws {
        // given
        let payload: [String: JSONValue] = ["nodes": .array([node("start", type: "start"), node("task", x: 100)]),
                                         "connections": .array([.object(["id": .string("edge"), "source": .string("start"), "target": .string("task")])])]
        // when
        let result = try #require(WorkflowClipboard.pasted(payload, into: ["nodes": .array([node("existing", type: "start")])]))
        // then
        #expect(result.ids.count == 1)
        #expect(WorkflowJSON.nodes(result.definition).filter { $0.type == "start" }.count == 1)
        #expect(WorkflowJSON.edges(result.definition).isEmpty)
    }

    @Test func givenNegativeCopiedPositions_whenRepeatedlyPasted_thenGridPositionsStayPositiveAndDistinct() throws {
        // given
        let payload: [String: JSONValue] = ["nodes": .array([node("a", x: -105)])]
        // when
        let first = try #require(WorkflowClipboard.pasted(payload, into: [:]))
        let second = try #require(WorkflowClipboard.pasted(payload, into: first.definition))
        let positions = WorkflowJSON.nodes(second.definition).map(\.position)
        // then
        #expect(positions.count == 2 && positions[0] != positions[1])
        #expect(positions.allSatisfy { $0.x >= 0 && $0.y >= 0 
            && $0.x.truncatingRemainder(dividingBy: 10) == 0 && $0.y.truncatingRemainder(dividingBy: 10) == 0
        })
    }
}
