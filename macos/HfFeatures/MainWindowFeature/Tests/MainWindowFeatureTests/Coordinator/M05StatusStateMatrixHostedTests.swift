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

    private static func base(_ state: String, title: String = "Fix the flaky retry path in the slot release",
                             build: @escaping @MainActor () throws -> M05MatrixRunner.Built,
                             ready: @escaping @MainActor (M05MatrixRunner.Context) -> Bool,
                             verify: @escaping @MainActor (M05MatrixRunner.Context) throws -> Void) -> M05MatrixRunner.Spec {
        M05MatrixRunner.Spec(suite: "status", state: state, config: { _ in
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

    private static func running() -> M05MatrixRunner.Spec {
        base("running-stop", build: {
            .init(harness: M05Fixtures.harness(M05Fixtures.task(status: "running")))
        }, ready: { $0.has("Stop") && $0.principalHas(prefix: "Running") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.principalHas(prefix: "Running"), "badge Running \(ctx.name) \(ctx.principalStrings)")
            let stop = try #require(ctx.element("Stop"))
            #expect(ShellMatrix.isEnabled(stop) == true, "composer Stop enabled \(ctx.name)")
            for absent in ["Stop requested", "Settling", "Current status unavailable", "Cancelled", "Reconstructed outcome"] {
                #expect(!ctx.has(absent), "no notice or banner \(absent) \(ctx.name)")
            }
        })
    }

    private static func stopRequested() -> M05MatrixRunner.Spec {
        let fixtures = TaskDetailVMTests.Fixtures()
        var spec = base("stop-requested", build: {
            .init(harness: M05Fixtures.harness(M05Fixtures.task(status: "running"), fixtures: fixtures))
        }, ready: { $0.has("Stopping…") && $0.has("Stop requested") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.has("This run has not exited yet. The status changes when Harflow records the outcome."))
            let stop = try #require(ctx.element("Stopping…"))
            #expect(ShellMatrix.isEnabled(stop) == false, "Stopping… disabled \(ctx.name)")
            #expect(ctx.vm.task?.status == .running)
            #expect(ctx.principalHas(prefix: "Running"), "badge stays Running \(ctx.name) \(ctx.principalStrings)")
        })
        spec.drive = { _ in
            fixtures.stopping.value = true
            fixtures.stoppingSubject.send(())
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
            return .init(harness: harness, retained: [])
        }, ready: { $0.has("Settling") && $0.has(body) }, verify: { ctx in
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
        let task = M05Fixtures.task(status: failed ? "failed" : "completed")
        let title = failed ? "Outcome inferred, not observed" : "Reconstructed outcome"
        var spec = base(state, build: {
            let harness = M05Fixtures.harness(task)
            if failed {
                harness.observationBox.value = M05Fixtures.frame(history: .init(caughtUp: true, forwardDrained: true), logState: .incomplete)
            }
            return .init(harness: harness)
        }, ready: { $0.has(title) }, verify: { ctx in
            commonChecks(ctx)
            if failed {
                #expect(ctx.has("Harflow never saw this process exit and found no result in its output, so it reports failed. "
                    + "Nothing it had already written was undone."))
                let proceed = try #require(ctx.element("Continue in a new session"))
                #expect(ShellMatrix.isEnabled(proceed) == false, "Continue disabled \(ctx.name)")
                #expect(ctx.has("Open Events"))
                #expect(ctx.principalHas(prefix: "Failed"), "badge Failed \(ctx.name) \(ctx.principalStrings)")
            } else {
                #expect(ctx.has("Harflow did not see this process exit. Done comes from the run's own closing output."))
                #expect(ctx.principalHas(prefix: "Done · exit not observed"), "badge \(ctx.name) \(ctx.principalStrings)")
            }
        })
        spec.drive = { ctx in ctx.harness.tasksSubject.send([task]) }
        return spec
    }

    private static func ownerWarning(_ state: String) -> M05MatrixRunner.Spec {
        let lost = state == "owner-lost"
        let task = M05Fixtures.task(status: "running", fields: ["supervision": .object(["owner_state": .string(lost ? "dead" : "undecidable")])])
        let title = lost ? "The process watching this run is gone" : "Harflow can't confirm this run"
        var spec = base(state, build: { .init(harness: M05Fixtures.harness(task)) }, ready: { $0.has(title) }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.has("Stop task"))
            #expect(ctx.has("Refresh"))
            let stop = try #require(ctx.element("Stop task"))
            #expect(ShellMatrix.isEnabled(stop) == true)
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
        let fixtures = TaskDetailVMTests.Fixtures()
        let outcome = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: running))
        fixtures.statusReadProvider.value = { _ in outcome.value }
        var spec = base("status-unavailable", build: { .init(harness: M05Fixtures.harness(running, fixtures: fixtures)) },
                        ready: { $0.has("Current status unavailable") }, verify: { ctx in
            commonChecks(ctx)
            #expect(ctx.has("The engine did not answer. Everything below was read earlier and may be out of date."))
            let retry = try #require(ctx.element("Retry read"))
            #expect(ShellMatrix.isEnabled(retry) == true)
            #expect(ctx.vm.messageBoxModel.placeholder == "Unavailable until status can be read")
            #expect(!ctx.has("Stop"), "no Stop \(ctx.name)")
            #expect(ctx.principalHas(prefix: "Status unavailable"), "badge \(ctx.name) \(ctx.principalStrings)")
        })
        spec.drive = { ctx in
            ctx.harness.tasksSubject.send([running])
            // A first good read has been admitted; only the read outcome changes now.
            outcome.value = .init(revision: 2, task: nil)
            fixtures.statusReadSubject.send(())
        }
        return spec
    }

    // MARK: Continuation banners

    private static func banner(_ state: String) -> M05MatrixRunner.Spec {
        let status = state == "cancelled" ? "cancelled" : state == "timed-out" ? "timed_out" : "failed"
        let landmark = switch state {
        case "cancelled": "Files already written stay in place. Harflow did not undo anything."
        case "timed-out": "Timed out here means the limit on turns, not a clock. Files already written stay in place."
        default: "Task failed: the harness exited with code 1"
        }
        var spec = base(state, build: {
            let fixture = HostedContinuationFixture()
            fixture.publish([HostedContinuationFixture.task(status: status)])
            return .init(harness: fixture.vm, retained: [fixture])
        }, ready: { $0.has(landmark) && $0.has("task-state-continue") }, verify: { ctx in
            commonChecks(ctx)
            let proceed = try #require(ctx.element("task-state-continue"))
            #expect(ShellMatrix.isEnabled(proceed) == true, "Continue enabled \(ctx.name)")
            #expect(ctx.has("Continue in a new session"))
            switch state {
            case "cancelled":
                #expect(ctx.has("Cancelled"))
            case "timed-out":
                #expect(ctx.has("This run stopped at its turn limit"))
                #expect(ctx.has("Copy resume command"))
            default:
                #expect(ctx.principalHas(prefix: "Failed"), "badge Failed \(ctx.name) \(ctx.principalStrings)")
            }
        })
        spec.drive = { ctx in
            ctx.harness.tasksSubject.send([HostedContinuationFixture.task(status: status)])
        }
        return spec
    }

    private static func continuation(_ state: String) -> M05MatrixRunner.Spec {
        let reason = "Backend declined this exact source: session unavailable."
        let result: Result<ProcessOutput, ToolError> = switch state {
        case "launch-unknown": .failure(.timedOut(tool: "fixture ctl", seconds: 1))
        case "continue-refused": .success(HostedContinuationCtl.response(reason: reason))
        default: .success(HostedContinuationCtl.response(task: "accepted-session"))
        }
        let holder = FixtureHolder()
        let landmark = switch state {
        case "launch-unknown": "A new session may have started"
        case "continue-starting": "Starting…"
        case "continue-started": "New session accepted"
        default: "The engine refused this request."
        }
        var spec = base(state, build: {
            let fixture = HostedContinuationFixture(result: result)
            holder.fixture = fixture
            fixture.publish([HostedContinuationFixture.task()])
            return .init(harness: fixture.vm, retained: [fixture])
        }, ready: { $0.has(landmark) }, verify: { ctx in
            commonChecks(ctx)
            switch state {
            case "launch-unknown":
                #expect(ctx.has("The engine did not report back after Continue, so a task may exist. Don't resend yet."))
                #expect(ctx.has("Check for a new task"))
                #expect(ctx.vm.messageBoxModel.placeholder == "Locked until the new session is checked")
            case "continue-starting":
                let starting = try #require(ctx.element("Starting…"))
                #expect(ShellMatrix.isEnabled(starting) == false, "Starting… disabled \(ctx.name)")
                #expect(ctx.vm.messageBoxModel.placeholder == "Starting a new session…")
            case "continue-started":
                #expect(ctx.has("The engine accepted the request. It may still be waiting for resources; acceptance does not mean completion."))
            default:
                #expect(ctx.has(reason), "raw reason shown \(ctx.name)")
                #expect(ctx.has("New task"))
                #expect(ctx.has("Copy resume command"))
            }
        })
        spec.drive = { ctx in
            guard let fixture = holder.fixture else { return }
            ctx.harness.tasksSubject.send([HostedContinuationFixture.task()])
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.has("task-state-continue") }
            if let button = ctx.element("task-state-continue") { _ = ShellMatrix.press(button) }
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return fixture.runner.latch.arrived.value }
            // Continue-starting stays held; the others answer now.
            if state != "continue-starting" { await fixture.runner.latch.release() }
        }
        spec.finish = { _ in
            if state == "continue-starting" { await holder.fixture?.runner.latch.release() }
        }
        return spec
    }

    final class FixtureHolder { var fixture: HostedContinuationFixture? }
}
