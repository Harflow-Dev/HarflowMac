import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - M05StatusStateMatrixHostedTests

/// Native evidence for the sixteen Status states of HarflowDesign `v2/scripts/screens-m05-proposal.js` (pin 4ff7d83): each is
/// the production shell with a real standalone `TaskDetailVM`, at 1280x800 and 1000x620, in light and dark. The assertions
/// state what native renders; they do not establish pixel fidelity. Triggers that exist only through fixtures (taken over, the
/// chain-stop refusal, the engine's unknown-outcome evidence) are rendered from those fixtures and say so in the receipt.
@MainActor
@Suite(.serialized)
struct M05StatusStateMatrixHostedTests {
    nonisolated static let states = M05StateTable.ids(.status)

    @Test(arguments: states, [false, true])
    func givenApprovedStatusState_whenHostedInBothSizes_thenNativeStateRenders(state: String, dark: Bool) async throws {
        // given / when / then
        try await M05MatrixRunner.run(Self.spec(state), dark: dark)
    }

    // MARK: Recipes

    static func spec(_ state: String) -> M05MatrixRunner.Spec {
        switch state {
        case "running-stop": running()
        case "stop-requested": stopRequested()
        case "cancelled", "timed-out", "failed-continue": banner(state)
        case "settling": settling()
        case "unknown-failed", "unknown-done": unknownOutcome(state)
        case "owner-lost", "unverified": ownerWarning(state)
        case "launch-unknown", "continue-starting", "continue-started", "continue-refused": continuation(state)
        case "status-unavailable": statusUnavailable()
        case "taken-over": takenOver()
        default: preconditionFailure("No recipe for status state \(state)")
        }
    }

    private static let suiteName = M05StateTable.Suite.status.rawValue

    private static func base(_ state: String, title: String = "Fix the flaky retry path in the slot release",
                             build: @escaping @MainActor () throws -> M05MatrixRunner.Built,
                             ready: @escaping @MainActor (M05MatrixRunner.Context) -> Bool,
                             verify: @escaping @MainActor (M05MatrixRunner.Context) throws -> Void) -> M05MatrixRunner.Spec {
        M05MatrixRunner.Spec(suite: suiteName, state: state, config: { _ in
            var config = TopBarIntegratedFixture.Config()
            config.title = title
            config.closePane = true
            config.notices = 0
            config.continuity = false
            return config
        }, build: build, ready: ready, verify: verify)
    }

    /// What no state in this suite shows unless it is the state: the pane is closed and the composer is present.
    private static func commonChecks(_ ctx: M05MatrixRunner.Context) {
        #expect(!ctx.fixture.hasPane, "pane closed by default \(ctx.name)")
        let button = ctx.vm.messageBoxModel.buttonLabel
        #expect(!button.isEmpty && ctx.has(button), "composer action \(button) present \(ctx.name)")
    }

    /// The identifiers of the notices and banners that must be absent from a state that does not own them.
    private static let treatmentIDs = ["task-state-stopping", "task-state-settling", "task-state-statusUnavailable", "task-state-ownerLost",
                                       "task-state-unverified", "task-state-reconstructed", "task-state-unknownFailed",
                                       "task-continuation-eligible", "task-continuation-unknown", "task-continuation-refused"]

    /// Fixtures a recipe needs inside its own `build`, so each size starts from a fresh state.
    private final class Holder {
        var fixtures = TaskDetailVMTests.Fixtures()
        var outcome = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(nil)
        var continuation: HostedContinuationFixture?
    }

    private static func running() -> M05MatrixRunner.Spec {
        base("running-stop", build: {
            .init(harness: M05Fixtures.harness(M05Fixtures.task(status: "running")))
        }, ready: { $0.has("Stop") && $0.principalHas(prefix: "Running") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.principalHas(prefix: "Running"), "badge Running \(ctx.name) \(ctx.principalStrings)")
            let stop = try #require(ctx.element("Stop"))
            #expect(ShellMatrix.isEnabled(stop) == true, "composer Stop enabled \(ctx.name)")
            for absent in treatmentIDs { #expect(!ctx.has(absent), "no notice or banner \(absent) \(ctx.name)") }
        })
    }

    private static func stopRequested() -> M05MatrixRunner.Spec {
        let holder = Holder()
        var spec = base("stop-requested", build: {
            holder.fixtures = TaskDetailVMTests.Fixtures()
            return .init(harness: M05Fixtures.harness(M05Fixtures.task(status: "running"), fixtures: holder.fixtures), retained: [holder])
        }, ready: { $0.has("Stopping…") && $0.has("task-state-stopping") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.within("task-state-stopping", has: "Stop requested"))
            #expect(ctx.within("task-state-stopping", has: "This run has not exited yet. The status changes when Harflow records the outcome."))
            let stop = try #require(ctx.element("Stopping…"))
            #expect(ShellMatrix.isEnabled(stop) == false, "Stopping… disabled \(ctx.name)")
            #expect(ctx.vm.task?.status == .running)
            #expect(ctx.principalHas(prefix: "Running"), "badge stays Running \(ctx.name) \(ctx.principalStrings)")
        })
        spec.drive = { _ in
            holder.fixtures.stopping.value = true
            holder.fixtures.stoppingSubject.send(())
        }
        return spec
    }

    private static func settling() -> M05MatrixRunner.Spec {
        let task = M05Fixtures.settled(fields: ["session_id": .string("fixture-session")])
        let body = "The run finished. Its last events and stored changes may still arrive."
        var spec = base("settling", build: {
            let harness = M05Fixtures.harness(task, stubChanges: false)
            let snapshot = try ChangesJSON.captureOnly(task: M05Fixtures.taskID, state: "pending", reason: "capture_settling")
            let script = ChangesReadScript(.snapshot(snapshot))
            given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
            return .init(harness: harness, retained: [script])
        }, ready: { $0.within("task-state-settling", has: "Settling") && $0.within("task-state-settling", has: body) }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.vm.stateTreatment?.isLeadingNotice == true)
            #expect(ctx.principalHas(prefix: "Done"), "badge Done \(ctx.name) \(ctx.principalStrings)")
            let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(ctx.host).first)
            let entries = try #require(table.owner?.entries)
            let notice = try #require(entries.firstIndex { if case .taskState = $0 { return true }; return false })
            for index in entries.indices { if case .row = entries[index] { #expect(notice < index, "notice before rows \(ctx.name)") } }
        })
        spec.drive = { ctx in
            ctx.harness.tasksSubject.send([task])
            M05Fixtures.publish(M05Fixtures.frame(items: [M05Fixtures.text(1, "Captured activity stays readable.")],
                history: .init(caughtUp: false, forwardDrained: false, currentness: .current), logState: .settling), to: ctx.harness)
        }
        return spec
    }

    private static func unknownOutcome(_ state: String) -> M05MatrixRunner.Spec {
        let failed = state == "unknown-failed"
        let task = M05Fixtures.task(status: failed ? "failed" : "completed", fields: failed ? ["resume_command": .string("fixture resume")] : [:])
        let id = failed ? "task-state-unknownFailed" : "task-state-reconstructed"
        let title = failed ? "Outcome inferred, not observed" : "Reconstructed outcome"
        var spec = base(state, build: {
            let harness = M05Fixtures.harness(task)
            if failed {
                harness.observationBox.value = M05Fixtures.frame(history: .init(caughtUp: true, forwardDrained: true), logState: .incomplete)
            }
            return .init(harness: harness)
        }, ready: { $0.within(id, has: title) }, verify: { ctx in
            commonChecks(ctx)
            if failed {
                #expect(ctx.within(id, has: "Harflow never saw this process exit and found no result in its output, so it reports failed. "
                    + "Nothing it had already written was undone."))
                let proceed = try #require(ctx.element("task-state-continue"))
                #expect(ShellMatrix.isEnabled(proceed) == false, "Continue disabled \(ctx.name)")
                #expect(ctx.has("task-state-open-events"))
                #expect(ctx.has("task-state-copy-resume"), "Copy resume command offered \(ctx.name)")
                #expect(ctx.principalHas(prefix: "Failed"), "badge Failed \(ctx.name) \(ctx.principalStrings)")
            } else {
                #expect(ctx.within(id, has: "Harflow did not see this process exit. Done comes from the run's own closing output."))
                #expect(ctx.principalHas(prefix: "Done · exit not observed"), "badge \(ctx.name) \(ctx.principalStrings)")
            }
        })
        spec.drive = { ctx in ctx.harness.tasksSubject.send([task]) }
        return spec
    }

    private static func ownerWarning(_ state: String) -> M05MatrixRunner.Spec {
        let lost = state == "owner-lost"
        let task = M05Fixtures.task(status: "running", fields: ["supervision": .object(["owner_state": .string(lost ? "dead" : "undecidable")])])
        let id = lost ? "task-state-ownerLost" : "task-state-unverified"
        let title = lost ? "The process watching this run is gone" : "Harflow can't confirm this run"
        let body = lost
            ? "Captured output has stopped and no later summary is promised. The run itself may still be working. "
                + "Check its changes or stop it before starting a replacement."
            : "It can't tell whether the process watching this run is alive. Output may or may not still be captured, "
                + "and a later summary is unknown. Check status again before starting a replacement."
        var spec = base(state, build: { .init(harness: M05Fixtures.harness(task)) }, ready: { $0.within(id, has: title) }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.within(id, has: body), "banner body \(ctx.name)")
            #expect(ctx.has("task-state-stop") && ctx.has("task-state-refresh"), "Stop task and Refresh \(ctx.name)")
            let stop = try #require(ctx.element("task-state-stop"))
            #expect(ShellMatrix.isEnabled(stop) == true)
            let badge = lost ? "Running · owner lost" : "Running · not verified"
            #expect(ctx.principalHas(prefix: badge), "badge \(badge) \(ctx.name) \(ctx.principalStrings)")
        })
        spec.drive = { ctx in ctx.harness.tasksSubject.send([task]) }
        return spec
    }

    private static func takenOver() -> M05MatrixRunner.Spec {
        let task = M05Fixtures.task(status: "cancelled", fields: ["taken_over": .bool(true), "exit_code": .number(1)])
        var spec = base("taken-over", build: { .init(harness: M05Fixtures.harness(task)) },
                        ready: { $0.has("Messages are off — you took this task over in Terminal") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.principalHas(prefix: "Cancelled"), "badge Cancelled \(ctx.name) \(ctx.principalStrings)")
            #expect(ctx.principalStrings.contains { $0.contains("taken over") }, "badge annotation \(ctx.name) \(ctx.principalStrings)")
            #expect(!ctx.vm.messageBoxModel.canSend)
        })
        spec.drive = { ctx in ctx.harness.tasksSubject.send([task]) }
        return spec
    }

    private static func statusUnavailable() -> M05MatrixRunner.Spec {
        let running = M05Fixtures.task(status: "running")
        let holder = Holder()
        var spec = base("status-unavailable", build: {
            holder.fixtures = TaskDetailVMTests.Fixtures()
            holder.outcome = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: running))
            let outcome = holder.outcome
            holder.fixtures.statusReadProvider.value = { _ in outcome.value }
            return .init(harness: M05Fixtures.harness(running, fixtures: holder.fixtures), retained: [holder])
        }, ready: { $0.within("task-state-statusUnavailable", has: "Current status unavailable") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.within("task-state-statusUnavailable", has: "The engine did not answer. Everything below was read earlier and may be out of date."))
            let retry = try #require(ctx.element("task-state-refresh"))
            #expect(ShellMatrix.isEnabled(retry) == true)
            #expect(ctx.vm.messageBoxModel.placeholder == "Unavailable until status can be read")
            #expect(!ctx.has("Stop"), "no Stop \(ctx.name)")
            #expect(ctx.principalHas(prefix: "Status unavailable"), "badge \(ctx.name) \(ctx.principalStrings)")
        })
        spec.drive = { ctx in
            ctx.harness.tasksSubject.send([running])
            // A first good read has been admitted; only the read outcome changes now.
            holder.outcome.value = .init(revision: 2, task: nil)
            holder.fixtures.statusReadSubject.send(())
        }
        return spec
    }

    // MARK: Continuation banners

    private static func banner(_ state: String) -> M05MatrixRunner.Spec {
        let status = state == "cancelled" ? "cancelled" : state == "timed-out" ? "timed_out" : "failed"
        let title = switch state {
        case "cancelled": "Cancelled"
        case "timed-out": "This run stopped at its turn limit"
        default: "Task failed: the harness exited with code 1"
        }
        let body = switch state {
        case "cancelled": "Files already written stay in place. Harflow did not undo anything."
        case "timed-out": "Timed out here means the limit on turns, not a clock. Files already written stay in place."
        default: ""
        }
        let id = "task-continuation-eligible"
        var spec = base(state, build: {
            let fixture = HostedContinuationFixture()
            fixture.publish([HostedContinuationFixture.task(status: status)])
            return .init(harness: fixture.vm, retained: [fixture])
        }, ready: { $0.within(id, has: title) && $0.has("task-state-continue") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.within(id, has: title), "banner title \(ctx.name)")
            if !body.isEmpty { #expect(ctx.within(id, has: body), "banner body \(ctx.name)") }
            let proceed = try #require(ctx.element("task-state-continue"))
            #expect(ShellMatrix.isEnabled(proceed) == true, "Continue enabled \(ctx.name)")
            #expect(ctx.has("Continue in a new session"), "button label \(ctx.name)")
            if state != "failed-continue" { #expect(ctx.has("task-state-copy-resume"), "Copy resume command in the banner \(ctx.name)") }
            let badge = switch state {
            case "cancelled": "Cancelled"
            case "timed-out": "Timed out"
            default: "Failed"
            }
            #expect(ctx.principalHas(prefix: badge), "badge \(badge) \(ctx.name) \(ctx.principalStrings)")
        })
        spec.drive = { ctx in
            ctx.harness.tasksSubject.send([HostedContinuationFixture.task(status: status)])
        }
        return spec
    }

    private static func verifyContinuation(_ state: String, id: String, reason: String, _ ctx: M05MatrixRunner.Context) throws {
        commonChecks(ctx)
        switch state {
        case "launch-unknown":
            #expect(ctx.within(id, has: "The engine did not report back after Continue, so a task may exist. Don't resend yet."))
            #expect(ctx.has("task-state-check") && ctx.has("Check for a new task"))
            #expect(ctx.vm.messageBoxModel.placeholder == "Locked until the new session is checked")
        case "continue-starting":
            let starting = try #require(ctx.element("task-state-continue"))
            #expect(ShellMatrix.isEnabled(starting) == false, "Starting… disabled \(ctx.name)")
            #expect(ctx.has("Starting…"))
            #expect(ctx.vm.messageBoxModel.placeholder == "Starting a new session…")
        case "continue-started":
            #expect(ctx.vm.currentTaskID == "accepted-session")
            #expect(ctx.principalHas(prefix: "Running"), "badge Running \(ctx.name) \(ctx.principalStrings)")
            // Native keeps the accepted notice after the recorded successor is adopted, beside the Running badge, as the design does.
            #expect(ctx.within(id, has: "New session accepted"), "accepted notice kept after adoption \(ctx.name)")
        default:
            #expect(ctx.within(id, has: "The engine refused this request."), "refusal body \(ctx.name)")
            #expect(ctx.within(id, has: reason), "raw reason shown \(ctx.name)")
            #expect(ctx.has("task-state-new-task"), "New task \(ctx.name)")
            #expect(ctx.has("task-state-copy-resume"), "Copy resume command \(ctx.name)")
        }
        if state != "continue-started" { #expect(ctx.principalHas(prefix: "Failed"), "badge Failed \(ctx.name) \(ctx.principalStrings)") }
    }

    private static func continuation(_ state: String) -> M05MatrixRunner.Spec {
        let reason = "Backend declined this exact source: session unavailable."
        let holder = Holder()
        let (id, title) = switch state {
        case "launch-unknown": ("task-continuation-unknown", "A new session may have started")
        case "continue-starting": ("task-continuation-starting", "Task failed: the harness exited with code 1")
        case "continue-started": ("task-continuation-accepted", "New session accepted")
        default: ("task-continuation-refused", "Continue was refused")
        }
        var spec = base(state, build: {
            let result: Result<ProcessOutput, ToolError> = switch state {
            case "launch-unknown": .failure(.timedOut(tool: "fixture ctl", seconds: 1))
            case "continue-refused": .success(HostedContinuationCtl.response(reason: reason))
            default: .success(HostedContinuationCtl.response(task: "accepted-session"))
            }
            let fixture = HostedContinuationFixture(result: result)
            holder.continuation = fixture
            fixture.publish([HostedContinuationFixture.task()])
            return .init(harness: fixture.vm, retained: [fixture, holder])
        }, ready: { ctx in
            state == "continue-started"
                ? ctx.vm.currentTaskID == "accepted-session" && ctx.principalHas(prefix: "Running")
                : ctx.within(id, has: title)
        }, verify: { ctx in try verifyContinuation(state, id: id, reason: reason, ctx) })
        spec.drive = { ctx in
            guard let fixture = holder.continuation else { return }
            ctx.harness.tasksSubject.send([HostedContinuationFixture.task()])
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.has("task-state-continue") }
            if let button = ctx.element("task-state-continue") { _ = ShellMatrix.press(button) }
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return fixture.runner.latch.arrived.value }
            // Continue-starting stays held; the others answer now.
            if state != "continue-starting" { await fixture.runner.latch.release() }
            if state == "continue-started" {
                await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.within(id, has: title) }
                #expect(ctx.within(id, has: title), "accepted notice shown before adoption \(ctx.name)")
                #expect(ctx.within(id, has: "The engine accepted the request. It may still be waiting for resources; acceptance does not mean completion."))
                // Positive recorded evidence and conversation adoption arrive, so the new session is the current member.
                fixture.pages.result = .success(HostedContinuationPages.page(["accepted-session"]))
                let successor = HostedContinuationFixture.task(id: "accepted-session", status: "running", predecessor: fixture.sourceID)
                fixture.installMember("accepted-session")
                fixture.fixtures.successorObservationEffect.value = { _ in
                    fixture.members.value = [HostedContinuationFixture.task(), successor]
                    return false
                }
                fixture.publishFreshStatusRead()
            }
        }
        spec.finish = { _ in await holder.continuation?.runner.latch.release() }
        return spec
    }
}
