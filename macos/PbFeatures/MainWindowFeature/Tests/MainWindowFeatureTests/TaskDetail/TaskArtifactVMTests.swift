import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - TaskDetailVMTests

extension TaskDetailVMTests {
    private func artifactPage(taskID: String, artifactID: String, cursor: String?) throws -> TaskArtifactPage {
        let item: JSONValue = .object([
            "artifact_id": .string(artifactID), "task_id": .string(taskID), "kind": .string("report"),
            "note": .string("Full note\n🙂"), "path": .string("/tmp/shared"), "registered_at": .string("now"),
            "provenance": .object(["method": .string("verified_process_lineage"), "task_id": .string(taskID)]),
            "availability": .object(["state": .string("available"), "observed_at": .string("later")])
        ])
        return try #require(TaskArtifactPage(raw: ["task_id": .string(taskID), "items": .array([item]),
            "next_cursor": cursor.map(JSONValue.string) ?? .null, "has_more": .bool(cursor != nil),
            "state": .string("available"), "count": .number(2)], taskID: taskID))
    }

    @Test func givenPagesSharingPathsAcrossTasks_whenLoaded_thenExactArtifactIdentitiesArePreserved() async throws {
        // given
        let context = makeSUT()
        let first = try artifactPage(taskID: "a", artifactID: "first", cursor: "next")
        let second = try artifactPage(taskID: "a", artifactID: "second", cursor: nil)
        let other = try artifactPage(taskID: "b", artifactID: "first", cursor: nil)
        context.sut.artifactMembers = [ArtifactMemberModel(id: "a"), ArtifactMemberModel(id: "b")]
        given(context.useCase).artifactPage(taskID: .any, cursor: .any).willProduce { id, cursor in
            .success(id == "b" ? other : cursor == nil ? first : second)
        }
        // when
        context.sut.didLoadArtifacts(taskID: "a")
        await waitUntil { context.sut.artifactMembers[0].loaded }
        context.sut.didLoadArtifacts(taskID: "a")
        context.sut.didLoadArtifacts(taskID: "b")
        await waitUntil { context.sut.artifactMembers[0].items.count == 2 && context.sut.artifactMembers[1].loaded }
        // then
        #expect(context.sut.artifactMembers[0].items.map(\.artifactID) == ["first", "second"])
        #expect(context.sut.artifactMembers[1].items.map(\.taskID) == ["b"])
        #expect(context.sut.artifactMembers[0].items[0].id != context.sut.artifactMembers[1].items[0].id)
    }

    @Test func givenFailedArtifactPage_whenRetried_thenPagingResetsWithoutInventingZero() async {
        // given
        let context = makeSUT()
        context.sut.artifactMembers = [ArtifactMemberModel(id: "task", cursor: "stale", hasMore: true, loaded: true, count: 4)]
        given(context.useCase)
.artifactPage(taskID: .any, cursor: .any)
            .willReturn(.failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "stale cursor")))
        // when
        context.sut.didLoadArtifacts(taskID: "task")
        await waitUntil { context.sut.artifactMembers.first?.loading == false }
        // then
        #expect(context.sut.artifactMembers.first?.cursor == nil)
        #expect(context.sut.artifactMembers.first?.hasMore == false)
        #expect(context.sut.artifactMembers.first?.loaded == false)
        #expect(context.sut.artifactMembers.first?.count == nil)
        #expect(context.sut.artifactMembers.first?.message?.contains("unavailable") == true)
    }

    @Test func givenLoadingArtifactMetadata_whenDisappearing_thenWorkAndLoadingPresentationAreCleared() {
        // given
        let context = makeSUT()
        context.sut.artifactMembers = [ArtifactMemberModel(id: "task", loading: true)]
        let before = context.sut.artifactGeneration
        // when
        context.sut.didDisappear()
        // then
        #expect(context.sut.artifactMembers.isEmpty)
        #expect(context.sut.artifactRequests.isEmpty)
        #expect(context.sut.artifactGeneration != before)
        context.sut.conversationMembers = [task()]
        context.sut.recomputeArtifactMembers()
        #expect(context.sut.artifactMembers.first?.loading == false)
    }
}
