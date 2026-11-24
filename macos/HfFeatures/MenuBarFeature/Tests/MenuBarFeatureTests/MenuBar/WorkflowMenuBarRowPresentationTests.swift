import Foundation
@testable import MenuBarFeature
import MonitorCore
import Testing

// MARK: - WorkflowMenuBarRowPresentationTests

@Suite struct WorkflowMenuBarRowPresentationTests {
    private static let start = Date(timeIntervalSince1970: 1_793_059_200)

    private func row(status: String, startedAt: Date? = start, settling: Bool = false) throws -> WorkflowMenuBarRow {
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string("w1"), "name": .string("Run"), "status": .string(status), "settling": .bool(settling)
        ]
        if let startedAt { raw["created_at"] = .number(startedAt.timeIntervalSince1970) }
        return try #require(WorkflowMenuBarRow(raw))
    }

    @Test func givenRunningWithStart_whenTrailingResolved_thenElapsedSinceStart() throws {
        // given
        let sut = try row(status: "running")
        // when
        let trailing = WorkflowMenuBarRowView.trailing(for: sut)
        // then
        #expect(trailing == .elapsed(since: Self.start))
    }

    @Test func givenSettlingWithStart_whenTrailingResolved_thenStatusLabel() throws {
        // given
        let sut = try row(status: "completed", settling: true)
        // when
        let trailing = WorkflowMenuBarRowView.trailing(for: sut)
        // then
        #expect(trailing == .status("Settling"))
    }

    @Test func givenCancellingAndStartingWithStart_whenTrailingResolved_thenStatusLabel() throws {
        // given / when / then
        #expect(WorkflowMenuBarRowView.trailing(for: try row(status: "cancelling")) == .status("Cancelling"))
        #expect(WorkflowMenuBarRowView.trailing(for: try row(status: "starting")) == .status("Starting"))
    }

    @Test func givenRunningWithoutStart_whenTrailingResolved_thenStatusLabel() throws {
        // given
        let sut = try row(status: "running", startedAt: nil)
        // when
        let trailing = WorkflowMenuBarRowView.trailing(for: sut)
        // then
        #expect(trailing == .status("Running"))
    }

    @Test func givenNeedsAttentionWithStart_whenTrailingResolved_thenStatusLabel() throws {
        // given
        let sut = try row(status: "needs_attention")
        // when
        let trailing = WorkflowMenuBarRowView.trailing(for: sut)
        // then
        #expect(trailing == .status("Needs Attention"))
    }

    @Test func givenPausedAndSettledWithStart_whenTrailingResolved_thenStatusLabel() throws {
        // given / when / then
        #expect(WorkflowMenuBarRowView.trailing(for: try row(status: "paused")) == .status("Paused"))
        #expect(WorkflowMenuBarRowView.trailing(for: try row(status: "completed")) == .status("Completed"))
    }
}
