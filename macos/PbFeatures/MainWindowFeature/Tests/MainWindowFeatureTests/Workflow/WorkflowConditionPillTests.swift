import AppKit
@testable import MainWindowFeature
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowConditionPillTests

@MainActor @Suite(.serialized) struct WorkflowConditionPillTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenLongMultilineCondition_whenHosted_thenCaptionIsBoundedToOneNativeLine(appearance: ColorScheme) async throws {
        // given
        let short = RedesignHost(WorkflowConditionPill(condition: "Continue").fixedSize().preferredColorScheme(appearance),
                                 size: CGSize(width: 400, height: 100))
        defer { short.close() }
        let condition = String(repeating: "Continue only after all required reviewers approve.\n", count: 20)
        let long = RedesignHost(WorkflowConditionPill(condition: condition).fixedSize().preferredColorScheme(appearance),
                                size: CGSize(width: 400, height: 100))
        defer { long.close() }

        // when
        await short.settle { short.host.fittingSize.height > 0 }
        await long.settle { long.host.fittingSize.height > 0 }
        let shortSize = short.host.fittingSize
        let longSize = long.host.fittingSize

        // then
        #expect(longSize.width > 0 && longSize.width <= PbRadius.Metrics.workflowConditionPillMaximumWidth + 1)
        #expect(abs(longSize.height - shortSize.height) < 1, "Multiline conditions remain a single decorative line")
        #expect(long.element(condition) == nil, "The decorative pill stays hidden from accessibility; the actual edge carries the full condition")
    }
}
