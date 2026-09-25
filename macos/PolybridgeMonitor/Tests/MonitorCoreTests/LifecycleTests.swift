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
        // Our process is gone and its pid now leads someone else's group: reported, not signalled.
        guard case .unconfirmed = ChildReaper.terminate(stale, grace: 0.2) else { return XCTFail() }
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

/// A scripted process table: each `lookup`/`group` answer can change per call, and signals are
/// only recorded — nothing real is touched.
final class FakeTable: ProcessTableReading, @unchecked Sendable {
    var lookups: [pid_t: ProcessTable.Lookup] = [:]
    var groupAnswer: [ProcessTable.Entry]? = []
    var onSignal: ((pid_t, Int32) -> Void)?
    private(set) var signals: [(pid_t, Int32)] = []

    func lookup(_ pid: pid_t) -> ProcessTable.Lookup { lookups[pid] ?? .absent }
    func group(_ pgid: pid_t) -> [ProcessTable.Entry]? { groupAnswer }

    func send(_ pid: pid_t, _ sig: Int32) {
        signals.append((pid, sig))
        onSignal?(pid, sig)
    }

    static func entry(_ identity: ProcessIdentity, pgid: pid_t, zombie: Bool = false) -> ProcessTable.Entry {
        ProcessTable.Entry(identity: identity, pgid: pgid, zombie: zombie)
    }
}

final class ChildReaperDecisionTests: XCTestCase {
    let leader = ProcessIdentity(pid: 500, startSeconds: 1000, startMicros: 1)
    let member = ProcessIdentity(pid: 501, startSeconds: 1001, startMicros: 0)

    func testAnUnreadableTableIsNeverReportedAsStopped() {
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.groupAnswer = [FakeTable.entry(leader, pgid: 500)]
        // The leader dies on SIGTERM, and from then on the table cannot be read.
        table.onSignal = { pid, sig in
            if sig == SIGTERM { table.lookups[pid] = .unreadable; table.groupAnswer = nil }
        }
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        guard case .unconfirmed = outcome else { return XCTFail("\(outcome)") }
    }

    func testAGroupReadFailureIsNotAnEmptyGroup() {
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.groupAnswer = nil
        table.onSignal = { pid, sig in if sig == SIGTERM { table.lookups[pid] = .absent } }
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        guard case .unconfirmed = outcome else { return XCTFail("\(outcome)") }
    }

    func testALeaderAlreadyGoneLeavesItsGroupUnconfirmedAndUnsignalled() {
        let table = FakeTable()
        table.groupAnswer = [FakeTable.entry(member, pgid: 500)]
        table.lookups[member.pid] = .entry(FakeTable.entry(member, pgid: 500))
        let outcome = ChildReaper.terminate(leader, grace: 0.1, killWait: 0.1, table: table, send: table.send)
        XCTAssertEqual(outcome, .unconfirmed(pids: [501], reason: "the terminal's process had already exited; what is left in its process group cannot be shown to be its own, so it was not signalled"))
        XCTAssertTrue(table.signals.isEmpty)
    }

    func testAReplacementGroupIsNeverAdopted() {
        let table = FakeTable()
        let stranger = ProcessIdentity(pid: 500, startSeconds: 9999, startMicros: 0)
        let strangerMember = ProcessIdentity(pid: 777, startSeconds: 9999, startMicros: 5)
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.groupAnswer = [FakeTable.entry(leader, pgid: 500)]
        // The leader exits on SIGTERM and its pid — and so the group id — is reused at once.
        table.onSignal = { pid, sig in
            guard pid == 500, sig == SIGTERM else { return }
            table.lookups[500] = .entry(FakeTable.entry(stranger, pgid: 500))
            table.lookups[777] = .entry(FakeTable.entry(strangerMember, pgid: 500))
            table.groupAnswer = [FakeTable.entry(stranger, pgid: 500), FakeTable.entry(strangerMember, pgid: 500)]
        }
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertFalse(table.signals.contains { $0.0 == 777 }, "the replacement group's member was never signalled")
        XCTAssertEqual(table.signals.filter { $0.0 == 500 }.map(\.1), [SIGHUP, SIGTERM], "nothing after the pid was reused")
    }

    func testAnOrphanedGroupWhoseLeaderExitedIsCleanedUpWhileContinuous() {
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.lookups[member.pid] = .entry(FakeTable.entry(member, pgid: 500))
        table.groupAnswer = [FakeTable.entry(leader, pgid: 500), FakeTable.entry(member, pgid: 500)]
        table.onSignal = { pid, sig in
            if pid == 500, sig == SIGTERM { // leader exits and is reaped; member ignores TERM
                table.lookups[500] = .absent
                table.groupAnswer = [FakeTable.entry(self.member, pgid: 500)]
            }
            if pid == 501, sig == SIGKILL {
                table.lookups[501] = .absent
                table.groupAnswer = []
            }
        }
        XCTAssertEqual(ChildReaper.terminate(leader, grace: 0.2, killWait: 0.5, table: table, send: table.send), .stopped)
        XCTAssertTrue(table.signals.contains { $0 == (501, SIGKILL) })
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
