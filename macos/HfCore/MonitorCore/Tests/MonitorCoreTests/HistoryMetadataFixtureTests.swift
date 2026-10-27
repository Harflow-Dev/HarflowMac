import Foundation
@testable import MonitorCore
import Testing

@Suite
struct HistoryMetadataFixtureTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "ContractsV1"
        ))
        return try Data(contentsOf: url)
    }

    private func result(_ name: String) throws -> [String: JSONValue] {
        let document = try #require(JSONValue.parse(fixture(name))?.objectValue)
        return try #require(document["result"]?.objectValue)
    }

    @Test
    func givenTaskPageMetadataFixture_whenDecoded_thenOwnershipNullAndFinishValuesArePreserved() throws {
        // given
        let page = try #require(TaskHistoryPage(raw: result("ctl-task-page-metadata.json")))

        // when
        let standalone = try #require(page.items.first { $0.id == "standalone-completed" })
        let owned = try #require(page.items.first { $0.id == "owned-completed" })
        let legacy = try #require(page.items.first { $0.id == "legacy-task" })

        // then
        #expect(standalone.raw["workflow_run_id"] == .null)
        #expect(standalone.raw["finished_at"]?.stringValue == "2026-10-27T00:00:00+00:00")
        #expect(owned.raw["workflow_run_id"]?.stringValue == "workflow-completed")
        #expect(owned.raw["finished_at"]?.stringValue == "2026-10-27T00:00:00+00:00")
        #expect(legacy.raw["workflow_run_id"] == nil)
        #expect(legacy.raw["finished_at"] == nil)
    }

    @Test
    func givenWorkflowPageMetadataFixture_whenDecoded_thenPinnedIdentitySettlingAndTimestampShapesSurvive() throws {
        // given
        let page = try #require(HistoryPage(raw: result("ctl-workflow-page-metadata.json")))

        // when
        let current = try #require(page.items.first { $0["workflow_run_id"]?.stringValue == "workflow-completed" })
        let legacy = try #require(page.items.first { $0["workflow_run_id"]?.stringValue == "workflow-legacy" })

        // then
        #expect(current["workflow_id"]?.stringValue == "workflow-generation-1")
        #expect(current["finished_at"]?.doubleValue == 1_793_059_200)
        #expect(current["settling"]?.boolValue == false)
        #expect(legacy["workflow_id"]?.stringValue == "legacy-183a8dfcff3bc6eeaa35d5d52f273a83")
        #expect(legacy["finished_at"] == nil)
        #expect(legacy["settling"]?.boolValue == false)
    }
}
