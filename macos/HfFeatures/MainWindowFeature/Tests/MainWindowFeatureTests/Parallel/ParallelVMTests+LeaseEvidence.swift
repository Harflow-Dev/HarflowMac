import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

extension ParallelVMTests {
    /// Member leases held by a visible group at the detail widths of common windows (1000, 1280, 1600 pt
    /// windows) and the workflow run's 448 pt lane area, for one-turn and two-turn conversations, at offset 0
    /// and half a stride in. With `HARFLOW_PARALLEL_LEASE_OUTPUT` set, the measurements are written as JSON.
    @Test func leasesFollowLaneIntersectionAtCommonWidths() async throws {
        var records: [[String: Any]] = []
        for width: CGFloat in [448, 736, 1016, 1336] {
            for turns in [1, 2] {
                for fraction: CGFloat in [0, 0.5] {
                    let harness = makeSUT()
                    let stride = ParallelTestGeometry.laneStride
                    harness.sut.updateViewport(offset: stride * fraction, width: width)
                    var tasks: [TaskInfo] = []
                    for lane in 0 ..< 8 {
                        for turn in 0 ..< turns {
                            tasks.append(task(id: "c\(lane)-t\(turn)", status: turn == turns - 1 ? "running" : "completed",
                                startedAt: Date(timeIntervalSince1970: Double(lane * 100 + turn)),
                                parentTaskID: turn == 0 ? nil : "c\(lane)-t\(turn - 1)"))
                        }
                    }
                    harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
                    harness.sut.didAppear()
                    harness.tasksSubject.send(tasks)
                    await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
                    records.append(["detail_width": Double(width), "turns": turns, "offset_fraction_of_stride": Double(fraction),
                                    "lane_floor": Double(ParallelLayout.minimumColumnWidth),
                                    "resident_conversations": harness.sut.residentColumnCount,
                                    "member_leases": harness.sut.leasedMemberCount])
                    #expect(harness.sut.leasedMemberCount == harness.sut.residentColumnCount * turns)
                    harness.sut.didDisappear()
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["HARFLOW_PARALLEL_LEASE_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
