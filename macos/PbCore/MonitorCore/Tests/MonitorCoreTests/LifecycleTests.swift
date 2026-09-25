import Foundation
@testable import MonitorCore
import Testing

/// Spawns real processes (`posix_spawn`), so every suite here runs serialized and kills what it
/// started when each test instance is torn down.
@Suite(.serialized)
final class ChildReaperTests {
    private var spawned: [pid_t] = []

    deinit {
        // Reap what the tests started (by pid, our own children only).
        for pid in spawned {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// A child in its own process group, like a pty session leader.
    private func spawn(_ script: String) throws -> ProcessIdentity {
        var pid: pid_t = 0
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)
        let args = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, &attrs, &argv, environ) == 0)
        spawned.append(pid)
        // Poll until the kernel process table has the child, rather than a fixed sleep.
        var identity: ProcessIdentity?
        let deadline = Date().addingTimeInterval(3)
        while identity == nil, Date() < deadline {
            identity = ProcessTable.lookup(pid)?.identity
            if identity == nil { usleep(20_000) }
        }
        return try #require(identity)
    }

    @Test
    func givenALeaderThatIgnoresSigterm_whenTerminated_thenItEscalatesToSigkillAndStops() throws {
        // given
        let leader = try spawn("trap '' TERM HUP; while :; do sleep 1; done")
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.5)
        // then
        #expect(outcome == .stopped)
        #expect(!ProcessTable.isLive(leader))
    }

    @Test
    func givenAGroupMemberThatOutlivesItsLeader_whenTerminated_thenTheMemberIsStoppedToo() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("member.pid").path
        // The leader dies on SIGTERM; the member it started ignores TERM/HUP.
        let leader = try spawn("sh -c 'trap \"\" TERM HUP; echo $$ > \(pidFile); while :; do sleep 1; done' & wait")
        // Poll for the nested shell to have written its own pid, rather than a fixed sleep.
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile), Date() < deadline { usleep(20_000) }
        let memberPid = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let member = try #require(ProcessTable.lookup(memberPid)?.identity)
        // when
        #expect(ProcessTable.group(leader.pid).map(\.identity.pid).contains(memberPid))
        let outcome = ChildReaper.terminate(leader, grace: 0.5)
        // then
        #expect(outcome == .stopped)
        #expect(!ProcessTable.isLive(member), "the member took SIGKILL")
    }

    @Test
    func givenAPidWhoseStartTimeNoLongerMatches_whenTerminated_thenItIsNeverSignalled() throws {
        // given
        let live = try spawn("exec sleep 30")
        let stale = ProcessIdentity(pid: live.pid, startSeconds: live.startSeconds - 100, startMicros: 0)
        // when
        // Our process is gone and its pid now leads someone else's group: reported, not signalled.
        let outcome = ChildReaper.terminate(stale, grace: 0.2)
        // then
        guard case .unconfirmed = outcome else { Issue.record("expected .unconfirmed, got \(outcome)"); return }
        #expect(ProcessTable.isLive(live), "a reused pid is someone else's process")
    }

    @Test
    func givenAnExitedChild_whenTerminated_thenItIsAlreadyGone() throws {
        // given
        let child = try spawn("exit 0")
        // Poll until the already-exiting script has actually become a zombie, rather than a fixed sleep.
        let deadline = Date().addingTimeInterval(3)
        while ProcessTable.isLive(child), Date() < deadline { usleep(20_000) }
        // when / then
        #expect(!ProcessTable.isLive(child), "a zombie has exited")
        #expect(ChildReaper.terminate(child) == .alreadyGone)
    }

    @Test
    func givenARawWaitStatus_whenDecoded_thenItMatchesExitedOrSignalled() {
        // given / when / then
        #expect(WaitStatus(raw: 256) == .exited(1))
        #expect(WaitStatus(raw: 0) == .exited(0))
        #expect(WaitStatus(raw: 9) == .signalled(9))
        #expect(WaitStatus(raw: 256).label == "exit 1")
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

@Suite(.serialized)
struct ChildReaperDecisionTests {
    let leader = ProcessIdentity(pid: 500, startSeconds: 1000, startMicros: 1)
    let member = ProcessIdentity(pid: 501, startSeconds: 1001, startMicros: 0)

    @Test
    func givenATableThatBecomesUnreadableAfterSigterm_whenTerminated_thenItIsNeverReportedAsStopped() {
        // given
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.groupAnswer = [FakeTable.entry(leader, pgid: 500)]
        // The leader dies on SIGTERM, and from then on the table cannot be read.
        table.onSignal = { pid, sig in
            if sig == SIGTERM { table.lookups[pid] = .unreadable; table.groupAnswer = nil }
        }
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        // then
        guard case .unconfirmed = outcome else { Issue.record("expected .unconfirmed, got \(outcome)"); return }
    }

    @Test
    func givenAGroupReadThatFails_whenTerminated_thenItIsNotTakenAsAnEmptyGroup() {
        // given
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.groupAnswer = nil
        table.onSignal = { pid, sig in if sig == SIGTERM { table.lookups[pid] = .absent } }
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        // then
        guard case .unconfirmed = outcome else { Issue.record("expected .unconfirmed, got \(outcome)"); return }
    }

    @Test
    func givenALeaderAlreadyGone_whenTerminated_thenItsGroupIsUnconfirmedAndUnsignalled() {
        // given
        let table = FakeTable()
        table.groupAnswer = [FakeTable.entry(member, pgid: 500)]
        table.lookups[member.pid] = .entry(FakeTable.entry(member, pgid: 500))
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.1, killWait: 0.1, table: table, send: table.send)
        // then
        #expect(
            outcome
                == .unconfirmed(pids: [501], reason: "the terminal's process had already exited; "
                    + "what is left in its process group cannot be shown to be its own, so it was not signalled")
        )
        #expect(table.signals.isEmpty)
    }

    @Test
    func givenAReplacementGroupAfterThePidIsReused_whenTerminated_thenTheReplacementIsNeverAdopted() {
        // given
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
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        // then
        #expect(outcome == .stopped)
        #expect(!table.signals.contains { $0.0 == 777 }, "the replacement group's member was never signalled")
        #expect(table.signals.filter { $0.0 == 500 }.map(\.1) == [SIGHUP, SIGTERM], "nothing after the pid was reused")
    }

    /// The first group read fails, so only the leader is known; SIGTERM kills it; a later scan
    /// finds a member with the leader gone. Nothing proves that member is not ours, so the result
    /// can never be .stopped while it is alive.
    @Test
    func givenAMemberFoundAfterAnUnreadableScan_whenTerminated_thenItIsNeverReadAsStopped() {
        // given
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.lookups[member.pid] = .entry(FakeTable.entry(member, pgid: 500))
        table.groupAnswer = nil
        table.onSignal = { pid, sig in
            if pid == 500, sig == SIGTERM {
                table.lookups[500] = .absent
                table.groupAnswer = [FakeTable.entry(member, pgid: 500)]
            }
        }
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send)
        // then
        guard case .unconfirmed(let pids, _) = outcome else { Issue.record("expected .unconfirmed, got \(outcome)"); return }
        #expect(pids == [501])
        #expect(!table.signals.contains { $0.0 == 501 }, "an unproven member is reported, not signalled")
    }

    @Test
    func givenAnUnreadableScanFollowedByAnEmptyCompleteScan_whenTerminated_thenThatIsProofOfStopping() {
        // given
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.groupAnswer = nil
        table.onSignal = { pid, sig in
            if pid == 500, sig == SIGTERM {
                table.lookups[500] = .absent
                table.groupAnswer = []
            }
        }
        // when / then
        #expect(ChildReaper.terminate(leader, grace: 0.2, killWait: 0.2, table: table, send: table.send) == .stopped)
    }

    @Test
    func givenAnOrphanedGroupWhoseLeaderExited_whenContinuous_thenItIsCleanedUp() {
        // given
        let table = FakeTable()
        table.lookups[leader.pid] = .entry(FakeTable.entry(leader, pgid: 500))
        table.lookups[member.pid] = .entry(FakeTable.entry(member, pgid: 500))
        table.groupAnswer = [FakeTable.entry(leader, pgid: 500), FakeTable.entry(member, pgid: 500)]
        table.onSignal = { pid, sig in
            if pid == 500, sig == SIGTERM { // leader exits and is reaped; member ignores TERM
                table.lookups[500] = .absent
                table.groupAnswer = [FakeTable.entry(member, pgid: 500)]
            }
            if pid == 501, sig == SIGKILL {
                table.lookups[501] = .absent
                table.groupAnswer = []
            }
        }
        // when
        let outcome = ChildReaper.terminate(leader, grace: 0.2, killWait: 0.5, table: table, send: table.send)
        // then
        #expect(outcome == .stopped)
        #expect(table.signals.contains { $0 == (501, SIGKILL) })
    }
}

@Suite(.serialized)
struct ChildAdoptionTests {
    @Test
    func givenAnUnidentifiableChild_whenAdopted_thenItIsKilledWithItsGroupNotLeftRunning() {
        // given
        var sent: [(pid_t, Int32)] = []
        // when
        let result = ChildAdoption.adopt(4321, attempts: 2, lookup: { _ in .unreadable }, send: { sent.append(($0, $1)) })
        // then
        #expect(result == .failure(.killed(4321)))
        #expect(sent.contains { $0 == (-4321, SIGKILL) })
        #expect(sent.contains { $0 == (4321, SIGKILL) })
    }

    @Test
    func givenAnIdentifiedChild_whenAdopted_thenNothingIsSignalled() {
        // given
        let identity = ProcessIdentity(pid: 4321, startSeconds: 5, startMicros: 0)
        var sent: [(pid_t, Int32)] = []
        // when
        let result = ChildAdoption.adopt(4321, lookup: { _ in .entry(FakeTable.entry(identity, pgid: 4321)) }, send: { sent.append(($0, $1)) })
        // then
        #expect(result == .success(identity))
        #expect(sent.isEmpty)
    }

    @Test
    func givenARealChildWhoseLookupFails_whenAdopted_thenItIsReallyStopped() throws {
        // given
        var pid: pid_t = 0
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)
        let args = ["/bin/sh", "-c", "trap '' TERM HUP; while :; do sleep 1; done"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, &attrs, &argv, environ) == 0)
        // when
        _ = ChildAdoption.adopt(pid, attempts: 1, lookup: { _ in .unreadable })
        // then
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        #expect(WaitStatus(raw: status) == .signalled(SIGKILL))
    }
}

@Suite(.serialized)
struct RefreshTriggerTests {
    @Test
    func givenPhaseAndRecordFileNames_whenCheckedForRelevance_thenOnlyPhaseAndRecordFilesTriggerARefresh() {
        // given / when / then
        #expect(RefreshTrigger.isRelevant("abc.meta.json"))
        #expect(RefreshTrigger.isRelevant("abc.takeover.1.ready"))
        #expect(RefreshTrigger.isRelevant("abc.takeover.2.attach"))
        #expect(RefreshTrigger.isRelevant("abc.cancel.1.sig"))
        #expect(!RefreshTrigger.isRelevant("abc.events.jsonl"))
        #expect(!RefreshTrigger.isRelevant("abc.jsonl"))
    }
}

@Suite(.serialized)
struct CascadeSummaryTests {
    @Test
    func givenACascadeWithSurvivorsAndUnsignalled_whenDescribed_thenItSaysWhatDidNotStop() {
        // given
        let result: [String: JSONValue] = [
            "task_id": .string("t"), "status": .string("cancelled"),
            "cascade": .object([
                "cancelled_descendants": .array([.string("a"), .string("b")]),
                "sigkill_survivors": .array([.string("c")]),
                "not_signalled": .array([.object(["task_id": .string("d"), "reason": .string("x")])]),
                "owner_still_settling": .array([])
            ])
        ]
        // when
        let text = CascadeSummary.describe(result)
        // then
        #expect(text.contains("status cancelled"))
        #expect(text.contains("2 sub-tasks cancelled"))
        #expect(text.contains("1 survived SIGKILL"))
        #expect(text.contains("1 not signalled"))
        #expect(!text.contains("settling"))
    }

    @Test
    func givenAnIncompleteCascade_whenDescribed_thenItIsSaid() {
        // given
        let result: [String: JSONValue] = ["status": .string("cancelled"), "cascade": .object([
            "cascade_incomplete": .bool(true), "unconverged": .array([.string("x"), .string("y")])
        ])]
        // when / then
        #expect(CascadeSummary.describe(result).contains("cascade incomplete: 2 descendants never reached"))
    }

    @Test
    func givenAPlainCancelWithNoCascade_whenDescribed_thenOnlyTheStatusIsShown() {
        // given / when / then
        #expect(CascadeSummary.describe(["status": .string("cancelled")]) == "Cancel sent · status cancelled")
    }
}
