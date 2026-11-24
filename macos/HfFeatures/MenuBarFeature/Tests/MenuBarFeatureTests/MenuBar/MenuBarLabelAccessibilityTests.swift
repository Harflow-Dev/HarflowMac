@testable import MenuBarFeature
import Testing

// MARK: - MenuBarLabelAccessibilityTests

@Suite struct MenuBarLabelAccessibilityTests {
    private func value(
        card: MenuBarRuntimeCard? = nil,
        taskLoading: Bool = false,
        running: Int = 2,
        workflowLoading: Bool = false,
        active: Int = 1,
        attention: Int = 1
    ) -> String {
        MenuBarLabelAccessibility.accessibilityValue(
            runtimeCard: card,
            counts: .init(
                taskCountsLoading: taskLoading, runningCount: running, workflowCountsLoading: workflowLoading,
                workflowActiveCount: active, workflowAttentionCount: attention
            )
        )
    }

    @Test func givenSetupRequired_whenValueBuilt_thenSublineReplacesCounts() {
        #expect(value(card: .setupRequired) == "Runtime setup required")
    }

    @Test func givenPreparing_whenValueBuilt_thenSublineReplacesCounts() {
        #expect(value(card: .preparing) == "Runtime setup in progress")
    }

    @Test func givenFailed_whenValueBuilt_thenSublineReplacesCounts() {
        #expect(value(card: .failed(message: "boom")) == "Runtime setup failed")
    }

    @Test func givenReady_whenValueBuilt_thenCountsAreReadAsBefore() {
        #expect(value() == "2 agents running, 1 workflows, 1 need attention")
    }

    @Test func givenReadyAndLoading_whenValueBuilt_thenLoadingPhrasesAreReadAsBefore() {
        #expect(value(taskLoading: true, workflowLoading: true) == "Agent count loading, Workflow count loading, Attention count loading")
    }
}
