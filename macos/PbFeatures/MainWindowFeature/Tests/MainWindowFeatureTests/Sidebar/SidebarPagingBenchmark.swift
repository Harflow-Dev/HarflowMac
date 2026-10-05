import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

/// Opt-in release measurement. Uses real decoding/grouping with the existing isolated use-case fixture;
/// no CLI, user's state directory, production UI or timing threshold is involved.
@MainActor
struct SidebarPagingBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PB_NATIVE_SIDEBAR_BENCHMARK"] == "1"))
    func givenThousandNestedHeaders_whenLoadingBoundedPage_thenReportDecodeAndGroupingTime() throws {
        let (all, document) = makeFixture()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("SidebarBenchmark-\(UUID().uuidString).json")
        try Data(document.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let fixture = SidebarVMTests().makeSUT()
        let vm = fixture.sut
        for sample in 1 ... 5 {
            let readStart = Date()
            let data = try Data(contentsOf: path)
            let readMS = Date().timeIntervalSince(readStart) * 1000
            let decodeStart = Date()
            let decoded = try CtlDocument.decode(stdout: data, stderr: "", exitCode: 0, command: "task-list-page").get()
            guard case .result(let raw) = decoded, let page = TaskHistoryPage(raw: raw) else {
                Issue.record("Benchmark page failed actual transport decode")
                return
            }
            let decodeMS = Date().timeIntervalSince(decodeStart) * 1000
            let groupingStart = Date()
            vm.latestTasks = page.items + page.relatedItems
            vm.conversationIndex = ConversationIndex(vm.latestTasks)
            vm.recompute()
            let groupingMS = Date().timeIntervalSince(groupingStart) * 1000
            print("PB_SIDEBAR_BENCHMARK sample=\(sample) fixture_headers=1000 page_headers=\(page.items.count) related=\(page.relatedItems.count) "
                  + "bytes=\(data.count) read_ms=\(readMS) decode_ms=\(decodeMS) grouping_ms=\(groupingMS) "
                  + "visible_rows=\(vm.sections.reduce(0) { $0 + $1.items.count })")
        }
        let loaded = all.compactMap { TaskInfo(.object($0)) }
        for sample in 1 ... 3 {
            let start = Date()
            vm.latestTasks = loaded
            vm.conversationIndex = ConversationIndex(loaded)
            vm.recompute()
            print("PB_SIDEBAR_BENCHMARK sample=\(sample) explicit_loaded_pages=10 headers=\(loaded.count) "
                  + "grouping_ms=\(Date().timeIntervalSince(start) * 1000) "
                  + "visible_rows=\(vm.sections.reduce(0) { $0 + $1.items.count })")
        }
    }

    private func makeFixture() -> ([[String: JSONValue]], String) {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let parents = (0 ..< 40).map { index -> [String: JSONValue] in
            var raw: [String: JSONValue] = ["task_id": .string("parent-\(index)"), "backend": .string("codex"),
                "status": .string("completed"), "repo_path": .string("/isolated/benchmark"),
                "started_at": .string(formatter.string(from: now.addingTimeInterval(Double(index - 1000)))),
                "session_id": .string("parent-session-\(index)"), "depth": .number(Double(index % 5))]
            if index % 5 != 0 {
                raw["parent_task_id"] = .string("parent-\(index - 1)")
                raw["spawned_by"] = raw["parent_task_id"]
                raw["root_task_id"] = .string("parent-\(index - index % 5)")
            }
            return raw
        }
        let children = (0 ..< 960).map { index -> [String: JSONValue] in
            let parent = index / 24
            return ["task_id": .string("child-\(index)"), "backend": .string("codex"), "status": .string("completed"),
                    "repo_path": .string("/isolated/benchmark"), "title": .string("Header \(index) " + String(repeating: "x", count: 120)),
                    "started_at": .string(formatter.string(from: now.addingTimeInterval(Double(index - 960)))),
                    "parent_task_id": .string("parent-\(parent)"), "spawned_by": .string("parent-\(parent)"),
                    "root_task_id": .string("parent-\(parent - parent % 5)"), "depth": .number(Double(parent % 5 + 1)),
                    "session_id": .string("child-session-\(parent)-\(index % 24 / 4)")]
        }
        let all = parents + children
        let recent = Array(children.suffix(100).reversed())
        let result: [String: JSONValue] = ["items": .array(recent.map(JSONValue.object)),
            "related_headers": .array(parents.suffix(10).map(JSONValue.object)), "next_cursor": .string("opaque-page2"),
            "has_more": .bool(true), "bootstrap_pending": .bool(false), "total_active_count": .number(0)]
        let document = JSONValue.object(["v": .number(5), "result": .object(result)]).rendered()
        return (all, document)
    }

}
