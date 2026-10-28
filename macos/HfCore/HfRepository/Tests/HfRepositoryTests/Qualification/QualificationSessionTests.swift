import Foundation
@testable import HfRepository
import MonitorCore
import Testing

struct QualificationSessionTests {
    private final class Fixture: QualificationRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var recorded: [(String, [String])] = []
        private var executable = "/fixture/generation/ctl"
        let checkHook: (@Sendable () async -> Void)?
        let plans: [BackendQualificationPlan]
        var checks: [(String, [String])] { lock.withLock { recorded } }
        init(plans: [BackendQualificationPlan], checkHook: (@Sendable () async -> Void)? = nil) { self.plans = plans; self.checkHook = checkHook }
        func replaceRuntime() { lock.withLock { executable = "/fixture/replacement/ctl" } }
        func runtimeToken() throws -> QualificationRuntimeToken {
            QualificationRuntimeToken(client: CtlClient(executable: lock.withLock { executable }, environment: [:]))
        }

        func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
            lock.withLock {
                defer { reads += 1 }
                return plans[min(reads, plans.count - 1)]
            }
        }

        func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {
            lock.withLock { recorded.append((backend, features)) }
            await checkHook?()
        }
    }

    private func plan(digest: String = "a", source: String = "seeded", ok: Bool = true) throws -> BackendQualificationPlan {
        let identity: JSONValue = .object(["backend": .string("fixture"), "version": .string("fixture"),
            "executable": .string("/fixture/harness"), "binary_sha256": .string(String(repeating: digest, count: 64)),
            "platform": .string("darwin-arm64")])
        return try #require(BackendQualificationPlan(["qualification_version": .number(1), "discovery_only": .bool(true),
            "requirements": .array([.object(["id": .string("task"), "backend": .string("fixture"), "identity": identity,
                "required_features": .array([.string("write")]), "features": .object(["write": .object([
                    "ok": .bool(ok), "source": .string(source), "identity": identity])])])])]))
    }

    @Test func givenCachedDiscovery_whenOpening_thenNoExplicitCheck() async throws {
        // given
        let fixture = Fixture(plans: [try plan()])
        let session = QualificationSession(repository: fixture)
        // when
        let snapshot = await session.discover(.task(options: []))
        // then
        #expect(snapshot.isReady)
        #expect(fixture.checks.isEmpty)
    }

    @Test func givenFailedEvidence_whenExplicitRetry_thenFreshDiscoveryControlsReadiness() async throws {
        // given
        let failed = try plan(source: "failed", ok: false)
        let fixture = Fixture(plans: [failed, failed, try plan(source: "auto-probed")])
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: []))
        // when
        let snapshot = await session.check()
        // then
        #expect(snapshot.isReady)
        #expect(fixture.checks.count == 1)
        #expect(fixture.checks.first?.0 == "fixture")
        #expect(fixture.checks.first?.1 == ["write"])
    }

    @Test func givenBinaryChangesDuringCheck_whenRediscovered_thenNeverAdoptSuccess() async throws {
        // given
        let original = try plan()
        let fixture = Fixture(plans: [original, original, try plan(digest: "b")])
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: []))
        // when
        let snapshot = await session.check()
        // then
        #expect(!snapshot.isReady)
        #expect(snapshot.phase == .failed(.evidenceChanged))
    }

    @Test func givenReadySnapshot_whenCancelled_thenRetainedEvidenceCannotEnableLaunch() async throws {
        // given
        let fixture = Fixture(plans: [try plan()])
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: []))
        // when
        await session.cancel()
        let snapshot = await session.snapshot
        // then
        #expect(snapshot.phase == .cancelled)
        #expect(!snapshot.isReady)
        #expect(snapshot.plan != nil)
    }

    private actor Suspension {
        private var entered = false
        private var released = false
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func suspend() async {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            if released { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiter = $0 }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @Test func givenSuspendedCheck_whenCancelledThenRetried_thenLateSuccessCannotRestoreCancelledReadiness() async throws {
        // given
        let gate = Suspension()
        let fixture = Fixture(plans: [try plan()], checkHook: { await gate.suspend() })
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: []))
        let pending = Task { await session.check() }
        await gate.waitForEntry()
        // when
        await session.cancel()
        await gate.release()
        _ = await pending.value
        // then
        #expect(await session.snapshot.phase == .cancelled)
        #expect(await session.snapshot.isReady == false)
        let retry = await session.check()
        #expect(retry.isReady)
    }

    @Test func givenSuspendedOldRequest_whenNewRequestDiscovered_thenOldAttemptCannotOverwriteIt() async throws {
        // given
        let gate = Suspension()
        let fixture = Fixture(plans: [try plan()], checkHook: { await gate.suspend() })
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: ["old"]))
        let pending = Task { await session.check() }
        await gate.waitForEntry()
        // when
        let replacement = await session.discover(.task(options: ["new"]))
        await gate.release()
        _ = await pending.value
        // then
        #expect(await session.snapshot == replacement)
    }

    @Test func givenSuspendedCheck_whenSelectedRuntimeReplaced_thenLateSuccessFailsClosed() async throws {
        // given
        let gate = Suspension()
        let fixture = Fixture(plans: [try plan()], checkHook: { await gate.suspend() })
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: []))
        let pending = Task { await session.check() }
        await gate.waitForEntry()
        // when
        fixture.replaceRuntime()
        await gate.release()
        let result = await pending.value
        // then
        #expect(!result.isReady)
        #expect(result.phase == .failed(.runtimeChanged))
    }

    @Test func givenSubscribedSession_whenCheckingSuspends_thenCurrentIdentityAndCancellationPublishCompleteSnapshots() async throws {
        // given
        let gate = Suspension()
        let fixture = Fixture(plans: [try plan()], checkHook: { await gate.suspend() })
        let session = QualificationSession(repository: fixture)
        var observer = await session.snapshots().makeAsyncIterator()
        let initial = await observer.next()
        #expect(initial?.phase == .idle)
        _ = await session.discover(.task(options: []))
        let discovered = await observer.next()
        #expect(discovered?.isReady == true)
        // when
        let pending = Task { await session.check() }
        await gate.waitForEntry()
        let checking = await observer.next()
        // then
        #expect(checking?.phase == .checking)
        #expect(checking?.checkingIdentity?.backend == "fixture")
        #expect(checking?.checkingIdentity?.version == "fixture")
        #expect(checking?.completedBackends.isEmpty == true)
        #expect(checking?.isReady == false)
        await session.cancel()
        let cancelled = await observer.next()
        #expect(cancelled?.phase == .cancelled)
        #expect(cancelled?.checkingIdentity == nil)
        await gate.release()
        _ = await pending.value
        #expect(await session.snapshot == cancelled)
    }

    @Test func givenUnsupportedCapability_whenDiscovering_thenStructuredToolFailureRetained() async {
        // given
        let session = QualificationSession(repository: NullQualificationRepository())
        // when
        let snapshot = await session.discover(.task(options: []))
        // then
        guard case .failed(.tool(.unsupportedCommand)) = snapshot.phase else {
            Issue.record("Unsupported capability must remain classifiable without string matching")
            return
        }
        #expect(!snapshot.isReady)
    }

    @Test func givenLongFailureDetail_whenPresenting_thenBoundedWithoutLosingToolClassification() {
        // given
        let error = ToolError.launchFailed(tool: "harflow-ctl", detail: String(repeating: "x", count: 2000))
        // when
        let failure = QualificationFailure(error: error)
        // then
        #expect(failure == .tool(error))
        #expect(failure.displayMessage.count == 1000)
        #expect(QualificationFailure(error: QualificationSessionError.missingIdentity) == .missingIdentity)
    }

    @Test func givenRuntimeChangedAfterDiscovery_whenUserExplicitlyRetries_thenCurrentRuntimeIsRebound() async throws {
        // given
        let fixture = Fixture(plans: [try plan()])
        let session = QualificationSession(repository: fixture)
        _ = await session.discover(.task(options: []))
        fixture.replaceRuntime()
        // when
        let snapshot = await session.check()
        // then
        #expect(snapshot.isReady)
        #expect(snapshot.runtime?.executable == "/fixture/replacement/ctl")
        #expect(fixture.checks.count == 1)
    }

}
