import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

extension TaskListRepositoryImplTests {

    // MARK: Explicit titles (listing `title`)

    private func listingClient(_ entries: [String]) -> CtlClient {
        let runner = StubProcessRunner(output: historyStdout(#"{"v":2,"tasks":[\#(entries.joined(separator: ","))]}"#))
        return CtlClient(executable: "/bin/echo", environment: [:], runner: runner)
    }

    private func entry(_ id: String, status: String = "running", title: String? = nil) -> String {
        let titleField = title.map { #","title":"\#($0)""# } ?? ""
        return #"{"task_id":"\#(id)","status":"\#(status)","backend":"claude"\#(titleField)}"#
    }

    private func makeTasksDirectory(prompts: [String: String] = [:]) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (id, prompt) in prompts {
            try? (#"{"v":1,"seq":1,"kind":"task_started","prompt":"\#(prompt)"}"# + "\n")
                .write(to: dir.appendingPathComponent("\(id).events.jsonl"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func givenAListedTitle_whenRefreshed_thenItOverridesTheFallbackTitle() async {
        // given — a prompt-derived title is already on record for "a"
        let dir = makeTasksDirectory(prompts: ["a": "prompt title"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(listingClient([entry("a")])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()
        #expect(sut.titleLoadPassCount == 0)
        #expect(sut.title("a") == "Task a")

        // when
        resultBox.mutate { $0 = .success(listingClient([entry("a", title: "Explicit title")])) }
        await sut.refresh()

        // then
        #expect(sut.title("a") == "Explicit title")
        #expect(sut.titles["a"] == "Explicit title")
    }

    @Test func givenNoListedTitle_whenDisplayed_thenUsesTaskPrefixWithoutScanningLogs() async {
        // given — "a" has a prompt log, "b" has nothing, "c" has a blank title
        let dir = makeTasksDirectory(prompts: ["a": "prompt title"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(listingClient([
            entry("a"), entry("bbbbbbbbbbbb"), entry("cccccccccccc", title: "   ")
        ])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.refresh()
        #expect(sut.titleLoadPassCount == 0)

        // then
        #expect(sut.title("a") == "Task a")
        #expect(sut.title("bbbbbbbbbbbb") == "Task bbbbbbbb")
        #expect(sut.title("cccccccccccc") == "Task cccccccc")
    }

    @Test func givenAListedTitle_whenALatePromptLoaderPublishes_thenTheExplicitTitleIsKept() async {
        // given
        let dir = makeTasksDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(listingClient([entry("a", title: "Explicit title")])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()

        // when — a loader that started before the seeding publishes its prompt-derived value
        sut.mergeTitles(["a": "prompt title", "z": "other prompt"], failed: [])

        // then — existing-wins: the explicit title stays, unrelated ids still merge
        #expect(sut.title("a") == "Explicit title")
        #expect(sut.title("z") == "other prompt")
    }

    @Test func givenAnExplicitTitleThenAListingWithout_whenRefreshed_thenTheExplicitTitleIsKept() async {
        // given
        let dir = makeTasksDirectory(prompts: ["a": "prompt title"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(listingClient([entry("a", title: "Explicit title")])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()

        // when — an older writer drops the field on the next listing
        resultBox.mutate { $0 = .success(listingClient([entry("a")])) }
        await sut.refresh()

        // then
        #expect(sut.title("a") == "Explicit title")
    }

    @Test func givenAFinishedTaskWithAListedTitle_whenNotified_thenTheTitleClosureSeesTheExplicitTitle() async {
        // given — the closure is invoked inside `notify`, i.e. at dispatch time, not afterwards
        let dir = makeTasksDirectory(prompts: ["a": "prompt title"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(listingClient([entry("a")])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let finishNotifier = MockFinishNotifier()
        let titleSeen = LockedBox<String?>(nil)
        given(finishNotifier).notify(.any, titleFor: .any).willProduce { finished, titleFor in
            if let id = finished.first?.taskID { titleSeen.mutate { $0 = titleFor(id) } }
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, finishNotifier: finishNotifier)
        await sut.refresh()
        #expect(sut.titleLoadPassCount == 0)

        // when
        resultBox.mutate { $0 = .success(listingClient([entry("a", status: "completed", title: "Explicit title")])) }
        await sut.refresh()

        // then
        #expect(titleSeen.value == "Explicit title")
    }

    @Test func givenAListedTitle_whenRefreshed_thenTheEventLogIsNotLoadedForThatId() async {
        // given — a readable prompt log exists, but the listing already carries a title
        let dir = makeTasksDirectory(prompts: ["a": "prompt title"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(listingClient([entry("a", title: "Explicit title")])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.refresh()

        // then — no background load was started at all (the missing-ids guard is synchronous)
        #expect(sut.titleLoadPassCount == 0)
        #expect(sut.title("a") == "Explicit title")
    }
}
