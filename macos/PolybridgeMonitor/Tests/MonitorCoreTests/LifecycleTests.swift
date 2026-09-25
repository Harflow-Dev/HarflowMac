import XCTest
@testable import MonitorCore

final class ChildReaperTests: XCTestCase {
    var spawned: [pid_t] = []

    override func tearDown() {
        // Reap what the tests started (by pid, our own children only).
        for pid in spawned {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        spawned = []
    }

    /// A child in its own process group, like a pty session leader.
    func spawn(_ script: String) throws -> ProcessIdentity {
        var pid: pid_t = 0
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)
        let args = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sh", nil, &attrs, &argv, environ), 0)
        spawned.append(pid)
        usleep(300_000)
        return try XCTUnwrap(ProcessTable.lookup(pid)?.identity)
    }

    func testEscalatesPastALeaderThatIgnoresSIGTERM() throws {
        let leader = try spawn("trap '' TERM HUP; while :; do sleep 1; done")
        XCTAssertEqual(ChildReaper.terminate(leader, grace: 0.5), .stopped)
        XCTAssertFalse(ProcessTable.isLive(leader))
    }

    func testAGroupMemberThatOutlivesItsLeaderIsStoppedToo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("member.pid").path
        // The leader dies on SIGTERM; the member it started ignores TERM/HUP.
        let leader = try spawn("sh -c 'trap \"\" TERM HUP; echo $$ > \(pidFile); while :; do sleep 1; done' & wait")
        let memberPid = try XCTUnwrap(pid_t(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let member = try XCTUnwrap(ProcessTable.lookup(memberPid)?.identity)
        XCTAssertEqual(ProcessTable.group(leader.pid).map(\.identity.pid).contains(memberPid), true)
        XCTAssertEqual(ChildReaper.terminate(leader, grace: 0.5), .stopped)
        XCTAssertFalse(ProcessTable.isLive(member), "the member took SIGKILL")
    }

    func testAPidWhoseStartTimeNoLongerMatchesIsNeverSignalled() throws {
        let live = try spawn("exec sleep 30")
        let stale = ProcessIdentity(pid: live.pid, startSeconds: live.startSeconds - 100, startMicros: 0)
        XCTAssertEqual(ChildReaper.terminate(stale, grace: 0.2), .alreadyGone)
        XCTAssertTrue(ProcessTable.isLive(live), "a reused pid is someone else's process")
    }

    func testAnExitedChildIsAlreadyGone() throws {
        let child = try spawn("exit 0")
        XCTAssertFalse(ProcessTable.isLive(child), "a zombie has exited")
        XCTAssertEqual(ChildReaper.terminate(child), .alreadyGone)
    }

    func testWaitStatusDecoding() {
        XCTAssertEqual(WaitStatus(raw: 256), .exited(1))
        XCTAssertEqual(WaitStatus(raw: 0), .exited(0))
        XCTAssertEqual(WaitStatus(raw: 9), .signalled(9))
        XCTAssertEqual(WaitStatus(raw: 256).label, "exit 1")
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
