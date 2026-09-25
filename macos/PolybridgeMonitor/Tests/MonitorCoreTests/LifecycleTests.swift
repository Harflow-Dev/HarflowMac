import XCTest
@testable import MonitorCore

final class ChildReaperTests: XCTestCase {
    func spawn(_ script: String) throws -> pid_t {
        var pid: pid_t = 0
        let args = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ), 0)
        return pid
    }

    func testEscalatesPastAChildThatIgnoresSIGTERM() throws {
        let pid = try spawn("trap '' TERM HUP; while :; do sleep 1; done")
        usleep(200_000)
        let started = Date()
        let outcome = ChildReaper.terminate(pid: pid, grace: 0.5)
        guard case .exited(let status) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(status & 0x7f, SIGKILL, "it took SIGKILL")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(kill(pid, 0), -1, "reaped: the pid no longer names our child")
    }

    func testAPoliteChildStopsOnSIGTERM() throws {
        let pid = try spawn("exec sleep 30")
        let outcome = ChildReaper.terminate(pid: pid, grace: 3)
        guard case .exited(let status) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotEqual(status & 0x7f, SIGKILL)
    }

    func testAnAlreadyReapedChildIsNeverSignalled() throws {
        let pid = try spawn("exit 0")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        XCTAssertEqual(ChildReaper.terminate(pid: pid), .alreadyGone)
    }
}

final class RefreshTriggerTests: XCTestCase {
    func testPhaseFilesAndRecordsTriggerARefresh() {
        XCTAssertTrue(RefreshTrigger.isRelevant("abc.meta.json"))
        XCTAssertTrue(RefreshTrigger.isRelevant("abc.takeover.1.ready"))
        XCTAssertTrue(RefreshTrigger.isRelevant("abc.takeover.2.attach"))
        XCTAssertTrue(RefreshTrigger.isRelevant("abc.cancel.1.sig"))
        XCTAssertFalse(RefreshTrigger.isRelevant("abc.events.jsonl"))
        XCTAssertFalse(RefreshTrigger.isRelevant("abc.jsonl"))
    }
}

final class CascadeSummaryTests: XCTestCase {
    func testSaysWhatDidNotStop() {
        let result: [String: JSONValue] = [
            "task_id": .string("t"), "status": .string("cancelled"),
            "cascade": .object([
                "cancelled_descendants": .array([.string("a"), .string("b")]),
                "sigkill_survivors": .array([.string("c")]),
                "not_signalled": .array([.object(["task_id": .string("d"), "reason": .string("x")])]),
                "owner_still_settling": .array([]),
            ]),
        ]
        let text = CascadeSummary.describe(result)
        XCTAssertTrue(text.contains("status cancelled"), text)
        XCTAssertTrue(text.contains("2 sub-tasks cancelled"), text)
        XCTAssertTrue(text.contains("1 survived SIGKILL"), text)
        XCTAssertTrue(text.contains("1 not signalled"), text)
        XCTAssertFalse(text.contains("settling"), text)
    }

    func testPlainCancel() {
        XCTAssertEqual(CascadeSummary.describe(["status": .string("cancelled")]), "Cancel sent · status cancelled")
    }
}
