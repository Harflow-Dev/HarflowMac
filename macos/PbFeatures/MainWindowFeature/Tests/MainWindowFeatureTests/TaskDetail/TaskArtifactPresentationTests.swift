@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskArtifactPresentationTests

struct TaskArtifactPresentationTests {
    @Test func givenStandaloneSnapshotWithFalseBuilder_whenClassified_thenArtifactsAreEligible() throws {
        // given
        let task = try #require(TaskInfo(.object(["task_id": .string("standalone"), "workflow_builder": .bool(false)])))
        // when / then
        #expect(ArtifactMemberModel.isStandalone(task))
    }

    @Test func givenWorkflowOwnerOrBuilder_whenClassified_thenArtifactsAreExcluded() throws {
        // given / when / then
        for field in ["workflow_run_id", "workflow_node_id", "workflow_role"] {
            let task = try #require(TaskInfo(.object(["task_id": .string("managed"), field: .string("owner")])))
            #expect(!ArtifactMemberModel.isStandalone(task))
        }
        let builder = try #require(TaskInfo(.object(["task_id": .string("builder"), "workflow_builder": .bool(true)])))
        #expect(!ArtifactMemberModel.isStandalone(builder))
    }
}
