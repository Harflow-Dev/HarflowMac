import Foundation
@testable import MonitorCore
import Testing

@Suite
struct TitlesTests {
    @Test
    func givenPromptText_whenBuildingATitle_thenTheFirstHeadingWinsAndLengthIsCapped() {
        // given / when / then
        #expect(TaskTitle.from(prompt: "\n\n## Quota exceeded sheet for Rapid\nmore") == "Quota exceeded sheet for Rapid")
        #expect(TaskTitle.from(prompt: "  \n ") == nil)
        let long = String(repeating: "x", count: 200)
        #expect(TaskTitle.from(prompt: long)?.count == TaskTitle.maxLength)
    }

    @Test
    func givenAnEventsFile_whenReadingTheFirstPrompt_thenOnlyTheStartedLineIsRead() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        try (
            eventLine(0, "task_started", #""prompt": "Fix the build""#) + "\n" + eventLine(1, "notice", #""text": "n""#) + "\n"
        ).write(toFile: path, atomically: true, encoding: .utf8)
        // when / then
        #expect(TaskTitle.firstPrompt(eventsPath: path) == "Fix the build")
        try (eventLine(0, "notice", #""text": "n""#) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(TaskTitle.firstPrompt(eventsPath: path) == nil)
        #expect(TaskTitle.firstPrompt(eventsPath: dir.appendingPathComponent("missing").path) == nil)
    }

    @Test
    func givenAHomeAndATaskID_whenBuildingPaths_thenTheyAreJoinedSafely() {
        // given / when / then
        #expect(TaskTitle.tasksDirectory(home: "/h") == "/h/.polybridge/tasks")
        #expect(TaskTitle.eventsPath(tasksDirectory: "/h/.polybridge/tasks", taskID: "abc") == "/h/.polybridge/tasks/abc.events.jsonl")
        #expect(TaskTitle.eventsPath(tasksDirectory: "/t", taskID: "../x") == nil)
    }

    @Test
    func givenLoginShellOutput_whenParsedForThePath_thenOnlyAWellFormedPathIsReturned() {
        // given / when / then
        #expect(LaunchEnvironment.parseLoginPath(Data("/opt/homebrew/bin:/usr/bin".utf8)) == "/opt/homebrew/bin:/usr/bin")
        #expect(LaunchEnvironment.parseLoginPath(Data("welcome!\n/a:/b".utf8)) == "/a:/b")
        #expect(LaunchEnvironment.parseLoginPath(Data("oops".utf8)) == nil)
        #expect(LaunchEnvironment.parseLoginPath(Data()) == nil)
    }
}
