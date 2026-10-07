@testable import MainWindowFeature
import MonitorCore
import Testing

struct WorkflowContextDeliveryTests {
    @Test func historicalTasksDoNotInventDeliveryOrUsage() {
        #expect(WorkflowContextDelivery(task: [:]).lines.isEmpty)
    }

    @Test func deliveryReportsMeasuredSizesAndCompatibilityWithoutClaimingTokenSavings() {
        let model = WorkflowContextDelivery(task: [
            "context_delivery": .object([
                "mode": .string("legacy"), "total_bytes": .number(100), "total_characters": .number(80),
                "compatibility_reason": .string("Native worker uses full context"),
                "budget_overflow_bytes": .number(20),
                "sections": .object(["evidence": .object(["bytes": .number(30)])])
            ])
        ])
        #expect(model.lines.contains("Delivered 100 bytes · 80 characters"))
        #expect(model.lines.contains("Native worker uses full context"))
        #expect(model.lines.contains("Required context exceeds target by 20 bytes"))
        #expect(model.lines.contains("evidence: 30 bytes"))
        #expect(!model.lines.contains { $0.contains("token") || $0.contains("cost") })
    }

    @Test func deltaDisplaysAcknowledgedBaseAndOnlyAvailableUsage() {
        let model = WorkflowContextDelivery(task: [
            "context_delivery": .object(["mode": .string("delta"), "revision": .number(2), "base_revision": .number(1)]),
            "prompt_usage": .object(["usage": .object(["input_tokens": .number(42)]), "cost_usd": .number(0.01)])
        ])
        #expect(model.lines.contains("Revision: 2"))
        #expect(model.lines.contains("Acknowledged base: 1"))
        #expect(model.lines.contains { $0.hasPrefix("Reported model usage:") })
        #expect(model.lines.contains("Reported cost: $0.01"))
    }

    @MainActor @Test func newDefinitionsOptInWithoutMigratingHistoricalDefinitions() {
        #expect(WorkflowVM.starterDefinition()["context_delivery"] == .string("optimized_v1"))
        let historical = WorkflowRecord(raw: ["name": .string("Historical")])
        #expect(historical.definition["context_delivery"] == nil)
    }
}
