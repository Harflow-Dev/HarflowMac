import XCTest
@testable import MonitorCore

final class TitlesTests: XCTestCase {
    func testTitleFromPrompt() {
        XCTAssertEqual(TaskTitle.from(prompt: "\n\n## Quota exceeded sheet for Rapid\nmore"), "Quota exceeded sheet for Rapid")
        XCTAssertNil(TaskTitle.from(prompt: "  \n "))
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(TaskTitle.from(prompt: long)?.count, TaskTitle.maxLength)
    }

    func testFirstPromptReadsOnlyTheStartedLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        try (eventLine(0, "task_started", #""prompt": "Fix the build""#) + "\n" + eventLine(1, "notice", #""text": "n""#) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(TaskTitle.firstPrompt(eventsPath: path), "Fix the build")
        try (eventLine(0, "notice", #""text": "n""#) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(TaskTitle.firstPrompt(eventsPath: path))
        XCTAssertNil(TaskTitle.firstPrompt(eventsPath: dir.appendingPathComponent("missing").path))
    }

    func testPaths() {
        XCTAssertEqual(TaskTitle.tasksDirectory(home: "/h"), "/h/.polybridge/tasks")
        XCTAssertEqual(TaskTitle.eventsPath(tasksDirectory: "/h/.polybridge/tasks", taskID: "abc"), "/h/.polybridge/tasks/abc.events.jsonl")
        XCTAssertNil(TaskTitle.eventsPath(tasksDirectory: "/t", taskID: "../x"))
    }

    func testParseLoginPath() {
        XCTAssertEqual(LaunchEnvironment.parseLoginPath(Data("/opt/homebrew/bin:/usr/bin".utf8)), "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(LaunchEnvironment.parseLoginPath(Data("welcome!\n/a:/b".utf8)), "/a:/b")
        XCTAssertNil(LaunchEnvironment.parseLoginPath(Data("oops".utf8)))
        XCTAssertNil(LaunchEnvironment.parseLoginPath(Data()))
    }
}
