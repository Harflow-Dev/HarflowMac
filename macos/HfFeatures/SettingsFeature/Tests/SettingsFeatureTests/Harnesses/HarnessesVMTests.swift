import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct HarnessesVMTests {
    
    private static func document(_ json: String) -> SetupDocument {
        // Feeds `makeSUT`'s default parameter value below, where Swift disallows `try` entirely —
        // this JSON is a fixed literal that cannot fail to decode.
        var object = JSONValue.parse(Data(json.utf8))!.objectValue!
        object["product"] = object["product"] ?? .string("harflow")
        object["format"] = object["format"] ?? .string("harflow.setup")
        object["product_version"] = object["product_version"] ?? .string("0.0.1")
        // swiftlint:disable:next force_try
        return try! SetupDocument.decode(stdout: Data(JSONValue.object(object).rendered().utf8), stderr: "", exitCode: 0).get()
    }
    
    func document(_ json: String) -> SetupDocument {
        Self.document(json)
    }
    
    private static let emptyDocumentJSON = #"{"product":"harflow","format":"harflow.setup","v":1,"product_version":"0.0.1","clients":[]}"#
    
    var twoRowsJSON: String {
        #"""
        {"product":"harflow","format":"harflow.setup","v":1,"product_version":"0.0.1","server_path":"/usr/local/bin/harflow","clients":[
            {"key":"claude-code","available":true,"installed":true,"current":true},
            {"key":"codex","available":true,"installed":false}
        ]}
        """#
    }
    
    static let setupClient = SetupClient(executable: "/bin/harflow-setup", environment: [:])
    
    private func makeSUT(
        status: Result<SetupDocument, ToolError> = .success(HarnessesVMTests.document(HarnessesVMTests.emptyDocumentJSON)),
        locate: Result<SetupClient, ToolError> = .success(HarnessesVMTests.setupClient),
        runtimeSetupState: RuntimeSetupState = .ready,
        routing: (any HarnessesRouting)? = nil
    ) -> (sut: HarnessesVM, useCase: MockHarnessesUseCase) {
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(status)
        given(useCase).locate().willReturn(locate)
        Self.stubRuntime(useCase, runtimeSetupState: runtimeSetupState)
        let sut = HarnessesVM(useCase: useCase, routing: routing)
        return (sut, useCase)
    }

    /// Every `HarnessesVM` construction reads `runtimeSetupState` in `init`, and `didAppear()` reads it again and
    /// subscribes to the publisher, so any test building its own `MockHarnessesUseCase` (bypassing `makeSUT`) needs
    /// these defaults too, or Mockable fatals on the unstubbed member.
    static func stubRuntime(
        _ useCase: MockHarnessesUseCase,
        runtimeSetupState: RuntimeSetupState = .ready,
        runtimeSetupPublisher: AnyPublisher<RuntimeSetupState, Never>? = nil
    ) {
        given(useCase).runtimeSetupState.willReturn(runtimeSetupState)
        given(useCase).runtimeSetupPublisher().willReturn(runtimeSetupPublisher ?? Just(runtimeSetupState).eraseToAnyPublisher())
    }
    
    /// `publishViewEvent`/`publishDialog` (`HfCommon.ViewModel`) dispatch via `Task { @MainActor in
    /// ... }`, not synchronously — so a subscriber set up just before the call can still see `nil`
    /// immediately after it returns. Every dialog-observing test below waits for the event to land
    /// before reading it, and — per `waitUntil`'s own contract ("it times out silently, so always
    /// `#expect` the condition afterwards") — always asserts the awaited condition explicitly rather
    /// than trusting the wait alone.
    func waitForDialog(_ sut: HarnessesVM, publish: () -> Void) async -> (dialog: AlertContent, cancellable: AnyCancellable) {
        var published: AlertContent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { event in
            if case .dialog(let dialog) = event { published = dialog }
        }
        publish()
        await waitUntil { published != nil }
        return (published!, cancellable)
    }
    
    // MARK: - Loading
    
    @Test func givenAppear_whenStatusSucceeds_thenRowsAndServerPathLoad() async {
        // given
        let (sut, _) = makeSUT(status: .success(document(twoRowsJSON)))
        
        // when
        sut.didAppear()
        
        // then
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.serverPath == "/usr/local/bin/harflow")
        #expect(sut.loadFailure == nil)
        #expect(sut.showsNoHarnesses == false)
        #expect(sut.showsRuntimeSetup == false)
    }

    @Test func givenARefusedStatus_whenLoaded_thenMessageHasNoCodeAndCodeLineCarriesIt() async {
        // given
        let failure = ToolError.refused(code: "denied", message: "harflow-setup refused the request.")
        let (sut, _) = makeSUT(status: .failure(failure))

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.loadFailure != nil }
        #expect(sut.loadFailure == HarnessLoadFailure(message: "harflow-setup refused the request.", code: "denied"))
        #expect(sut.rows.isEmpty)
        #expect(sut.serverPath == nil)
        #expect(sut.showsNoHarnesses == false)
    }

    @Test func givenAnUnsupportedSetupVersion_whenLoaded_thenRefusedBlockWithoutCode() async {
        // given
        let failure = ToolError.unsupportedCommand(tool: "harflow-setup", command: "status", detail: "unrecognized")
        let (sut, _) = makeSUT(status: .failure(failure))

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.loadFailure != nil }
        #expect(sut.loadFailure == HarnessLoadFailure(message: failure.message, code: nil))
        #expect(sut.rows.isEmpty)
        #expect(sut.serverPath == nil)
    }

    @Test(arguments: [
        ToolError.unreadable(tool: "harflow-setup", exitCode: 1, stderr: "boom"),
        ToolError.timedOut(tool: "harflow-setup", seconds: 8),
        ToolError.launchFailed(tool: "harflow-setup", detail: "crashed")
    ])
    func givenAnUnreadableTimeoutOrLaunchFailure_whenLoaded_thenTheSameRefusedBlockShowsWithoutCode(_ failure: ToolError) async {
        // given
        let (sut, _) = makeSUT(status: .failure(failure))

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.loadFailure != nil }
        #expect(sut.loadFailure == HarnessLoadFailure(message: failure.displayMessage, code: nil))
        #expect(sut.rows.isEmpty)
    }

    @Test func givenAnEmptySetupDocument_whenLoaded_thenNoHarnessesFound() async {
        // given
        let (sut, _) = makeSUT()

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.showsNoHarnesses }
        #expect(sut.showsNoHarnesses)
        #expect(sut.rows.isEmpty)
        #expect(sut.loadFailure == nil)
    }

    @Test func givenARefusedLoad_whenRefreshSucceeds_thenTheFailureClears() async {
        // given
        final class Answers { var failing = true }
        let answers = Answers()
        let populated = document(twoRowsJSON)
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willProduce {
            answers.failing ? .failure(.refused(code: "incompatible_runtime", message: "Incompatible Harflow runtime")) : .success(populated)
        }
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.loadFailure != nil }
        #expect(sut.loadFailure?.code == "incompatible_runtime")

        // when
        answers.failing = false
        sut.didTapRefresh()

        // then
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.loadFailure == nil)
    }

    @Test func givenALoadCompletes_whenObserved_thenIsLoadingEndsFalseAndRefreshIsNotDisabled() async {
        // given — Mockable's generated `willProduce` for an `async` member takes a synchronous
        // producer (confirmed against the framework source: `FunctionReturnBuilder.willProduce`
        // has no suspending overload), so `status()`/`perform()` cannot be held open from a test to
        // observe `isLoading`/`workingKey` mid-flight without flakiness. This test instead checks
        // the settled state `isRefreshDisabled` is derived from, which is what actually matters.
        let (sut, _) = makeSUT(status: .success(document(twoRowsJSON)))
        
        // when
        sut.didAppear()
        
        // then — positive setup first: the load genuinely completed (rows populated), so the
        // settled-state checks below prove something actually finished rather than matching a VM
        // that never loaded at all.
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.isLoading == false)
        #expect(sut.workingKey == nil)
        #expect(sut.isRefreshDisabled == false)
    }
    
    // MARK: - Install / Remove dialog
    
    @Test func givenDidTapInstall_whenPublished_thenTheDialogCopyMatchesTheOldConfirmation() async {
        // given
        let (sut, _) = makeSUT()
        let row = document(twoRowsJSON).rows[1] // codex, not installed
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstall(row) }
        
        // then
        #expect(dialog.title == "Install harflow into \(row.displayName)?")
        #expect(dialog.description == "This runs harflow-setup, which edits \(row.displayName)'s own configuration.")
        #expect(dialog.actions.first?.title == "Install")
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenAnOutOfDateRow_whenDidTapInstall_thenTheDialogOffersAnUpdate() async {
        // given
        let (sut, _) = makeSUT()
        let row = document(#"{"v":1,"clients":[{"key":"codex","available":true,"installed":true,"current":false}]}"#).rows[0]

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstall(row) }

        // then
        #expect(dialog.title == "Update harflow in \(row.displayName)?")
        #expect(dialog.actions.first?.title == "Update")
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenDidTapRemove_whenPublished_thenTheDialogCopyMatchesTheOldConfirmation() async {
        // given
        let (sut, _) = makeSUT()
        let row = document(twoRowsJSON).rows[0] // claude-code, installed
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        
        // then
        #expect(dialog.title == "Remove harflow from \(row.displayName)?")
        #expect(dialog.description == "This runs harflow-setup, which edits \(row.displayName)'s own configuration.")
        #expect(dialog.actions.first?.title == "Remove")
        #expect(dialog.actions.first?.role == nil) // the original Button had no role
        withExtendedLifetime(cancellable) {}
    }
    
    @Test func givenAHarnessActionSucceeds_whenCompleted_thenOnlyThatRowUpdates() async {
        // given — existing issue, preserved: the other row must be untouched by the action's result.
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        let installedDocument = document(#"""
        {"v":1,"clients":[{"key":"codex","available":true,"installed":true,"current":true,"action":"install"}]}
        """#)
        given(useCase).perform(.any, client: .value("codex"), using: .any).willReturn(.success(installedDocument))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        let claudeRowBefore = sut.rows.first { $0.key == "claude-code" }
        let codexRow = sut.rows.first { $0.key == "codex" }!
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstall(codexRow) }
        dialog.actions.first?.action()
        
        // then
        await waitUntil { sut.rows.first { $0.key == "codex" }?.installed == true }
        #expect(sut.rows.first { $0.key == "codex" }?.installed == true)
        #expect(sut.rows.first { $0.key == "claude-code" } == claudeRowBefore)
        // The action runs the exact client `run` located — one lookup, as the original did.
        verify(useCase).locate().called(1)
        verify(useCase).perform(.any, client: .value("codex"), using: .matching { $0.executable == "/bin/harflow-setup" }).called(1)
        withExtendedLifetime(cancellable) {}
    }
    
    @Test func givenAnActionFails_whenCompleted_thenOnlyThatRowCarriesTheFailureAndRowsAreUnchanged() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        let failure = ToolError.refused(code: "setup_error", message: "Could not update the configuration: permission denied")
        given(useCase).perform(.any, client: .value("claude-code"), using: .any).willReturn(.failure(failure))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        let rowsBefore = sut.rows
        let row = sut.rows.first { $0.key == "claude-code" }!
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        
        // then
        await waitUntil { !sut.rowFailures.isEmpty }
        #expect(sut.rowFailures == ["claude-code": HarnessRowFailure(
            message: "Could not update the configuration: permission denied", code: "setup_error", action: .remove)])
        #expect(sut.rows == rowsBefore)
        #expect(sut.loadFailure == nil)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenARowFailure_whenRetryConfirmed_thenTheSameActionRunsForTheSameRow() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase)
.perform(.any, client: .value("claude-code"), using: .any)
            .willReturn(.failure(.launchFailed(tool: "harflow-setup", detail: "crashed")))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "claude-code" }!
        let (first, firstCancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        first.actions.first?.action()
        await waitUntil { !sut.rowFailures.isEmpty }
        #expect(sut.rowFailures["claude-code"]?.action == .remove)

        // when — Retry asks for the same confirmation, then repeats the action
        let (retry, retryCancellable) = await waitForDialog(sut) { sut.didTapRetry(row) }
        retry.actions.first?.action()

        // then
        #expect(retry.title == "Remove harflow from \(row.displayName)?")
        #expect(retry.actions.first?.title == "Remove")
        await verify(useCase).perform(.any, client: .value("claude-code"), using: .any).calledEventually(2, before: .seconds(5))
        verify(useCase).perform(.any, client: .value("codex"), using: .any).called(0)
        withExtendedLifetime((firstCancellable, retryCancellable)) {}
    }

    @Test func givenARowFailure_whenTheRowActionSucceeds_thenTheFailureClears() async {
        // given
        final class Answers { var failing = true }
        let answers = Answers()
        let installed = document(#"{"v":1,"clients":[{"key":"codex","available":true,"installed":true,"current":true,"action":"install"}]}"#)
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase).perform(.any, client: .value("codex"), using: .any).willProduce { _, _, _ in
            answers.failing ? .failure(.launchFailed(tool: "harflow-setup", detail: "crashed")) : .success(installed)
        }
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "codex" }!
        let (first, firstCancellable) = await waitForDialog(sut) { sut.didTapInstall(row) }
        first.actions.first?.action()
        await waitUntil { !sut.rowFailures.isEmpty }
        #expect(sut.rowFailures["codex"]?.action == .install)

        // when
        answers.failing = false
        let (retry, retryCancellable) = await waitForDialog(sut) { sut.didTapRetry(row) }
        retry.actions.first?.action()

        // then
        await waitUntil { sut.rowFailures.isEmpty }
        #expect(sut.rowFailures.isEmpty)
        #expect(sut.rows.first { $0.key == "codex" }?.installed == true)
        withExtendedLifetime((firstCancellable, retryCancellable)) {}
    }

    @Test func givenARowFailure_whenRefreshSucceeds_thenAllRowFailuresClear() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase).perform(.any, client: .any, using: .any).willReturn(.failure(.launchFailed(tool: "harflow-setup", detail: "crashed")))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "claude-code" }!
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        await waitUntil { !sut.rowFailures.isEmpty }
        #expect(sut.rowFailures.count == 1)

        // when
        sut.didTapRefresh()

        // then
        await verify(useCase).status().calledEventually(2, before: .seconds(5))
        await waitUntil { sut.rowFailures.isEmpty && !sut.isLoading }
        #expect(sut.rowFailures.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    // Regression (item 8): the original's `run` located `harflow-setup` BEFORE setting `working`
    // (`SettingsView.swift:134`) — a locator failure was a silent no-op, leaving both `working` and
    // `error` untouched. `load()`'s own locator failure is unaffected and still surfaces normally
    // (covered by `givenARefusedStatus_whenLoaded_thenMessageHasNoCodeAndCodeLineCarriesIt` above).
    @Test func givenTheLocatorFailsInRun_whenAnActionIsConfirmed_thenItIsASilentNoOp() async {
        // given — the status load itself succeeds (so rows exist to act on), but the separate
        // locate the original ran again inside `run` fails.
        let locateFailure = ToolError.notFound(tool: "harflow-setup", searched: ["/usr/local/bin"])
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase).locate().willReturn(.failure(locateFailure))
        given(useCase).perform(.any, client: .any, using: .any).willReturn(.failure(locateFailure))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "claude-code" }!
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        // `run` is `Task { ... }`-dispatched from the dialog action; wait for `locate()` to have
        // actually run (proving the Task itself ran) rather than a fixed sleep, before asserting the
        // silent no-op that should follow it.
        await verify(useCase).locate().calledEventually(1, before: .seconds(5))
        
        // then — neither `working` nor `error` moved, and the real `perform` (the action itself)
        // was never even attempted.
        #expect(sut.workingKey == nil)
        #expect(sut.rowFailures.isEmpty)
        verify(useCase).perform(.any, client: .any, using: .any).called(0)
        withExtendedLifetime(cancellable) {}
    }

    // MARK: - Runtime not ready

    @Test func givenRuntimeNotReady_whenAppearing_thenNoStatusOrBackendsCallAndSetupBlockShows() async {
        // given
        let (sut, useCase) = makeSUT(runtimeSetupState: .installationRequired(installedVersion: nil, requiredVersion: "0.0.14"))

        // when
        sut.didAppear()
        sut.didTapRefresh()
        await Task.yield()

        // then
        #expect(sut.showsRuntimeSetup)
        #expect(sut.isRefreshDisabled)
        #expect(sut.showsNoHarnesses == false)
        verify(useCase).status().called(0)
        verify(useCase).qualificationBackends().called(0)
        verify(useCase).qualificationSession().called(0)
    }

    @Test func givenRuntimeNotReady_whenOpenSetupTapped_thenRoutingOpensSetupOnce() {
        // given
        let routing = MockHarnessesRouting()
        given(routing).openSetup().willReturn()
        let (sut, _) = makeSUT(runtimeSetupState: .checking, routing: routing)

        // when
        sut.didTapOpenSetup()

        // then
        verify(routing).openSetup().called(1)
    }

    // MARK: - Generation guard and reload after install (settled plan, section 5)

    @Test func givenTheGenerationAdvancesMidFlight_whenTheOlderCallResolves_thenItsResultIsDropped() async {
        // given — Mockable's generated `willProduce` for an `async` member only takes a
        // *synchronous* producer (no suspending overload — see `FunctionReturnBuilder`), so two
        // genuinely-overlapping `load()` calls can't be raced directly. So instead the producer bumps
        // `sut.loadGeneration` itself, mid-call, simulating "a newer load already started" while
        // this one is still awaiting its own answer — exactly the race the guard exists to close.
        // `loadGeneration` is `internal`, not `private`: this test technique needs to reach it from
        // outside the file.
        final class SUTBox { var sut: HarnessesVM? }
        let sutBox = SUTBox()
        let staleDocumentJSON = #"{"v":1,"clients":[{"key":"claude-code","available":true,"installed":true,"current":true}]}"#
        let useCase = MockHarnessesUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).qualificationBackends().willReturn([])
        given(useCase).status().willProduce {
            sutBox.sut?.loadGeneration += 1
            return .success(Self.document(staleDocumentJSON))
        }
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubRuntime(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sutBox.sut = sut
        
        // when
        sut.didAppear()
        
        // then — the completion belongs to a generation that is already stale by the time it
        // resolves, so it must be dropped entirely: rows never populate, and `isLoading` — the
        // cleanup that used to be an unconditional `defer` — never clears either.
        await verify(useCase).status().calledEventually(1, before: .seconds(5))
        #expect(sut.rows.isEmpty)
        #expect(sut.isLoading == true)
    }

}
