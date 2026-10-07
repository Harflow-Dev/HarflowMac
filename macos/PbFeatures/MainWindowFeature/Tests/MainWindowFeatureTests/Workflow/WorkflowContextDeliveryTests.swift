@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowContextDeliveryTests

struct WorkflowContextDeliveryTests {
    @Test func givenHistoricalTask_whenReadingDelivery_thenNoMeasurementsAreInvented() {
        // given
        let task: [String: JSONValue] = [:]
        // when
        let model = WorkflowContextDelivery(task: task)
        // then
        #expect(model.lines.isEmpty)
    }

    @Test func givenDeliveryMeasurements_whenReadingLines_thenSizesAndCompatibilityAreReported() {
        // given
        let task: [String: JSONValue] = [
            "context_delivery": .object([
                "mode": .string("legacy"), "total_bytes": .number(100), "total_characters": .number(80),
                "compatibility_reason": .string("Native worker uses full context"),
                "budget_overflow_bytes": .number(20),
                "sections": .object(["evidence": .object(["bytes": .number(30)])])
            ])
        ]
        // when
        let model = WorkflowContextDelivery(task: task)
        // then
        #expect(model.lines.contains("Delivered 100 bytes · 80 characters"))
        #expect(model.lines.contains("Native worker uses full context"))
        #expect(model.lines.contains("Required context exceeds target by 20 bytes"))
        #expect(model.lines.contains("evidence: 30 bytes"))
        #expect(!model.lines.contains { $0.contains("token") || $0.contains("cost") })
    }

    @Test func givenAcknowledgedDelta_whenReadingLines_thenBaseAndAvailableUsageAreReported() {
        // given
        let task: [String: JSONValue] = [
            "context_delivery": .object(["mode": .string("delta"), "revision": .number(2), "base_revision": .number(1)]),
            "prompt_usage": .object(["usage": .object(["input_tokens": .number(42)]), "cost_usd": .number(0.01)])
        ]
        // when
        let model = WorkflowContextDelivery(task: task)
        // then
        #expect(model.lines.contains("Revision: 2"))
        #expect(model.lines.contains("Acknowledged base: 1"))
        #expect(model.lines.contains { $0.hasPrefix("Reported model usage:") })
        #expect(model.lines.contains("Reported cost: $0.01"))
    }

    @MainActor @Test func givenNewAndHistoricalDefinitions_whenReadingDelivery_thenOnlyNewDefinitionsOptIn() {
        // given
        let historical = WorkflowRecord(raw: ["name": .string("Historical")])
        // when
        let starter = WorkflowVM.starterDefinition()
        // then
        #expect(starter["context_delivery"] == .string("optimized_v1"))
        #expect(historical.definition["context_delivery"] == nil)
    }
}
