import AppKit
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskContinuationHostedTests + Wrapping

extension TaskContinuationHostedTests {
    @Test(arguments: [false, true])
    func givenNarrowContinueComponents_whenLongNoticeAndEngineReasonRender_thenEveryActionFitsMeasuredWidth(dark: Bool) async throws {
        // given
        let models: [TaskContinuationPresentation] = [
            .init(taskID: "source", phase: .accepted, status: .failed, locksActions: true),
            .init(taskID: "source", phase: .unknown, attemptID: UUID(), status: .failed, canCheck: true, locksActions: true),
            .init(taskID: "source", phase: .refused, status: .failed,
                  message: "The engine declined this source because its retained session is unavailable. Preserve this exact reason.")]
        let page = RedesignHost(VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                TaskContinuationBanner(model: model, showsCopyResumeCommand: true)
            }
            Spacer()
        }
.padding(8)
.frame(width: 320, height: 800, alignment: .topLeading)
.background(TaskScreenStyle.Colors.pageBackground.color)
.preferredColorScheme(dark ? .dark : .light), size: CGSize(width: 320, height: 800), appearance: dark ? .dark : .light)
        defer { page.close() }
        await page.settle { page.element("New session accepted") != nil && page.element("task-state-new-task") != nil }
        // when / then — inspect actual host geometry, including wrapped copy and the stacked action fallback.
        #expect(abs(page.host.bounds.width - 320) <= 1)
        #expect(abs(page.host.bounds.height - 800) <= 1)
        let engineReason = try #require(models[2].message)
        for text in [Self.acceptedBody, Self.unknownBody, engineReason, "task-state-check", "task-state-new-task", "Copy resume command"] {
            try assertVisibleText(text, in: page)
        }
        try await capture(page, name: "continue-components-320-\(dark ? "dark" : "light")")
    }
}
