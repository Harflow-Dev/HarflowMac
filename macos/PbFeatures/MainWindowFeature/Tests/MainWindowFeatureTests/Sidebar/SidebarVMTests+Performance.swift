import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - Large task regression

extension SidebarVMTests {
    @Test func givenA2000TaskListingWithABackendFilterActive_whenRecomputed_thenItStaysFarBelowTheQuadraticCost() async {
        // given — the exact shape measured at 0.36s/recompute on the real 532-task listing with a
        // backend tab selected (113 matches): `forcedExpandedIDs` used to rebuild the whole
        // conversation tree once per MATCHING task. `ConversationIndexTests` already proves the
        // underlying `ConversationIndex` fix in isolation; this proves it through the real VM path
        // (`recompute()` building one index per publication and reusing it — Plan review round 1,
        // item 1), at roughly 4x the real listing's size for headroom.
        let harness = makeSUT()
        let sut = harness.sut
        var tasks: [TaskInfo] = []
        for index in 0 ..< 2000 {
            tasks.append(task(
                id: "t\(index)", backend: index % 2 == 0 ? "claude" : "codex", status: index % 7 == 0 ? "running" : "completed",
                startedAt: .now.addingTimeInterval(-Double(index)),
                spawnedBy: index % 5 == 0 && index > 0 ? "t\(index - 1)" : nil,
                parentTaskID: index % 3 == 0 && index > 0 ? "t\(index - 1)" : nil
            ))
        }
        sut.didAppear()
        await sut.waitForPresentation()

        // Settle the real publisher first. Its receive(on: .main) hop can wait behind unrelated
        // concurrently running tests; that queue latency is not time spent building sidebar rows.
        harness.tasksSubject.send(tasks)
        await waitUntil { sut.latestTasks.count == 2000 }
        await sut.waitForPresentation()
        #expect(sut.latestTasks.count == 2000)
        let unfilteredCount = sut.runningRows.count + sut.recentRows.count

        // Measure the complete filter action/background presentation against the settled inventory.
        // The scheduler wait is included; the index has its own tight construction test.
        let start = Date()
        sut.didSelectBackendFilter("claude")
        await sut.waitForPresentation()
        let elapsed = Date().timeIntervalSince(start)

        // Keep behavior checks on the real published inventory; contextual ancestors may use
        // another backend, but filtering must retain matches and reduce the displayed inventory.
        #expect(sut.selectedBackend == "claude")
        #expect((sut.runningRows + sut.recentRows).contains { $0.backend == "claude" })
        #expect(sut.runningRows.count + sut.recentRows.count < unfilteredCount)
        // Retain the existing 3-second ceiling; ConversationIndexTests independently retain
        // their tight construction bound. This test measures actual VM work under that ceiling.
        #expect(
            elapsed < 3.0,
            "recompute() at 4x the real listing's size should stay well under the quadratic cost (\(elapsed)s)"
        )
    }
}
