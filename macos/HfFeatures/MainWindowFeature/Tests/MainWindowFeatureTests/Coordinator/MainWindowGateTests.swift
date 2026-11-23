import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct MainWindowGateTests {
    private let root = "/tmp/harflow-fixture-home/.harflow"

    private func classify(_ error: ToolError?, ready: Bool = true, store: StoreRecoveryState = .idle) -> MainWindowGate? {
        MainWindowGate.classify(runtimeReady: ready, listError: error, storeState: store)
    }

    private let drawnRefusal = ToolError.structuredRefusal(
        code: "state_incompatible",
        message: "Unsupported state root: foreign store marker; inspect state or select a fresh state root",
        data: ["reason": .string("foreign_store"), "state_root": .string("/Users/me/Library/Application Support/Harflow/State")]
    )

    private func inspection(status: String, reason: String, message: String) -> StateInspection {
        StateInspection([
            "state_root": .string(root), "engine_version": .string("0.0.2"), "status": .string(status),
            "reason": .string(reason), "message": .string(message),
            "recovery_supported": .bool(false), "cooperative_ownership_only": .bool(true)
        ])!
    }

    private func incompatibility(_ detail: String) -> ToolError { WireEnvelope.incompatibility(detail) }

    // MARK: Drawn fixtures

    @Test func givenCtlAnswersContractVersionTwo_whenClassified_thenContractRefusedWithTheDrawnStatus() {
        // given
        let error = WireEnvelope.validate(
            ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(2),
             "product_version": .string(HarflowVersion.current)],
            contract: .ctl
        )
        // when
        let gate = classify(error)
        // then
        #expect(gate == .contractRefused(status: "harflow-ctl answered with contract version 2; this app understands version 1. "
            + "Update the app or harflow so they match.", code: nil))
    }

    @Test func givenAMissingEventsContract_whenClassified_thenCapabilityMissingWithTheDrawnStatusAndCode() {
        // given
        let data = Data("""
        {"product":"harflow","format":"harflow.version-info","v":1,"product_version":"\(HarflowVersion.current)","component":"engine",
        "state_root":"\(root)","contracts":{"ctl":{"format":"harflow.ctl","v":1}},
        "capabilities":["ctl.v1","setup.v1","events.v1","version-info.v1"],"os":"darwin","architecture":"arm64"}
        """.utf8)
        guard case .failure(let error) = VersionInfoDocument.decode(
            stdout: data, context: RuntimeCompatibilityContext(expectedStateRoot: root), requiring: [.events]
        ) else { Issue.record("expected an incompatible runtime"); return }
        // when
        let gate = classify(error)
        // then
        #expect(gate == .capabilityMissing(
            status: "Incompatible Harflow runtime: missing required events.v1 contract/capability", code: "incompatible_runtime"))
    }

    // MARK: Classification table

    @Test func givenEachMissingRequiredDetail_whenClassified_thenCapabilityMissingWithTheCode() {
        for detail in [WireEnvelope.Detail.missingCapability("events.v1"), WireEnvelope.Detail.missingContract("ctl.v1")] {
            // given / when
            let gate = classify(incompatibility(detail))
            // then
            #expect(gate == .capabilityMissing(status: "Incompatible Harflow runtime: " + detail, code: "incompatible_runtime"))
        }
    }

    @Test func givenEachAllowlistedMismatchDetail_whenClassified_thenContractRefusedWithTheCode() {
        // given
        let details = [
            WireEnvelope.Detail.unsupportedFormat("harflow.ctl"),
            WireEnvelope.Detail.releaseLineDiffers(from: "0.0.14"),
            WireEnvelope.Detail.requiresDarwinArm64,
            WireEnvelope.Detail.foreignProductIdentity,
            WireEnvelope.Detail.invalidProductVersion,
            WireEnvelope.Detail.invalidVersionInfo
        ]
        for detail in details {
            // when
            let gate = classify(incompatibility(detail))
            // then
            #expect(gate == .contractRefused(status: "Incompatible Harflow runtime: " + detail, code: "incompatible_runtime"), "\(detail)")
        }
    }

    @Test func givenOtherIncompatibilityDetails_whenClassified_thenNoGate() {
        // given
        let details = [
            "task listing superseded by selected runtime change", "invalid nested event",
            "version-info must be one bounded JSON document", "invalid selected compatibility context",
            "", "unsupported format"
        ]
        for detail in details {
            // when / then
            #expect(classify(incompatibility(detail)) == nil, "\(detail)")
        }
    }

    @Test func givenAnUnsupportedCommandListing_whenClassified_thenCapabilityMissingWithoutACode() {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-list-page", detail: "usage")
        // when
        let gate = classify(error)
        // then
        #expect(gate == .capabilityMissing(status: error.message, code: nil))
    }

    @Test func givenErrorsThatAreNotRuntimeMismatches_whenClassified_thenNoGate() {
        // given
        let errors: [ToolError] = [
            .timedOut(tool: "harflow-ctl task-list-page", seconds: 30),
            .unreadable(tool: "harflow-ctl", exitCode: 1, stderr: ""),
            .launchFailed(tool: "harflow-ctl", detail: "no such file"),
            .notFound(tool: "harflow-ctl", searched: ["/bin"]),
            .refused(code: "state_incompatible", message: "Unsupported state root"),
            .refused(code: "managed_runtime_unavailable", message: "missing"),
            .refused(code: "incompatible_runtime", message: "Not prefixed"),
            .structuredRefusal(code: "incompatible_runtime", message: "Incompatible Harflow runtime: missing required x", data: [:])
        ]
        for error in errors {
            // when / then
            #expect(classify(error) == nil, "\(error)")
        }
    }

    @Test func givenARuntimeThatIsNotReady_whenAnyErrorIsClassified_thenNoGate() {
        // given
        let error = ToolError.unsupportedVersion(tool: "harflow-ctl", version: "2")
        // when / then
        #expect(classify(error, ready: false) == nil)
        #expect(classify(nil) == nil)
    }

    @Test func givenAGateError_whenOwnsIsAsked_thenItAgreesWithClassify() {
        #expect(MainWindowGate.owns(.unsupportedVersion(tool: "harflow-ctl", version: "2")))
        #expect(!MainWindowGate.owns(.timedOut(tool: "harflow-ctl", seconds: 1)))
        #expect(!MainWindowGate.owns(nil))
    }

    // MARK: Store gate

    @Test func givenTheDrawnForeignStoreRefusal_whenClassified_thenStoreUnusableWithTheDrawnContent() {
        // given / when
        let gate = classify(nil, store: .incompatible(drawnRefusal))
        // then
        guard case .storeUnusable(let attention) = gate else { Issue.record("expected a store gate, got \(String(describing: gate))"); return }
        #expect(attention.title == "Task store needs attention")
        #expect(attention.message == "Unsupported state root: foreign store marker; inspect state or select a fresh state root")
        #expect(!attention.message.contains("state_incompatible"))
        #expect(attention.stateRoot == "/Users/me/Library/Application Support/Harflow/State")
        #expect(attention.reason == "foreign_store")
        #expect(attention.code == nil)
    }

    @Test(arguments: [("incompatible", "foreign_store", "Task store needs attention"),
                      ("interrupted", "recovery_interrupted", "Recovery was interrupted")])
    func givenAnInspectionOfAnUnusableStore_whenClassified_thenStoreUnusableWithTheSettingsTitle(status: String, reason: String, title: String) {
        // given
        let value = inspection(status: status, reason: reason, message: "Engine sentence")
        // when
        let gate = classify(nil, store: .inspected(value))
        // then
        #expect(gate == .storeUnusable(StoreAttention.from(inspection: value)!))
        guard case .storeUnusable(let attention) = gate else { return }
        #expect(attention.title == title)
        #expect(attention.message == "Engine sentence")
    }

    @Test func givenStoreStatesThatAreNotAnUnusableStore_whenClassified_thenNoGate() {
        // given
        let incompatible = inspection(status: "incompatible", reason: "foreign_store", message: "x")
        let states: [StoreRecoveryState] = [
            .idle, .inspecting, .confirming(incompatible), .recovering(incompatible),
            .failed(drawnRefusal, inspection: nil), .failed(.timedOut(tool: "harflow-ctl", seconds: 8), inspection: incompatible),
            .inspected(inspection(status: "ready", reason: "compatible", message: "State is compatible")),
            .inspected(inspection(status: "missing", reason: "missing_root", message: "State root has not been initialized"))
        ]
        for state in states {
            // when / then
            #expect(classify(nil, store: state) == nil, "\(state)")
        }
    }

    @Test func givenAnIncompatibleStoreStateThatIsNotARefusal_whenClassified_thenNoGate() {
        // given: a managed-runtime error never gates here, and `from(refusal:)` returns nil for it
        let error = ToolError.refused(code: "managed_runtime_unavailable", message: "missing")
        // when / then
        #expect(classify(nil, store: .incompatible(error)) == nil)
        #expect(classify(nil, store: .incompatible(.timedOut(tool: "harflow-ctl", seconds: 8))) == nil)
    }

    @Test func givenAStoreRefusalAndAContractError_whenClassified_thenTheStoreGateWins() {
        // given
        let contract = ToolError.unsupportedVersion(tool: "harflow-ctl", version: "2")
        // when
        let gate = classify(contract, store: .incompatible(drawnRefusal))
        // then
        #expect(gate == .storeUnusable(StoreAttention(error: drawnRefusal)))
    }

    @Test func givenAStoreRefusalAndARuntimeThatIsNotReady_whenClassified_thenNoGate() {
        #expect(classify(nil, ready: false, store: .incompatible(drawnRefusal)) == nil)
    }

    @Test func givenTheStoreGate_whenTheSidebarIsAsked_thenItKeepsItsBodyAndTheContractGatesDoNot() {
        // given
        let store = MainWindowGate.storeUnusable(StoreAttention(error: drawnRefusal))
        // when / then
        #expect(!store.givesSidebarToSetupLine)
        #expect(MainWindowGate.contractRefused(status: "x", code: nil).givesSidebarToSetupLine)
        #expect(MainWindowGate.capabilityMissing(status: "x", code: nil).givesSidebarToSetupLine)
        #expect(!MainWindowGate.owns(drawnRefusal))
    }

    // MARK: Rendered copy

    @Test func givenTheDrawnStoreGate_whenCopyIsBuilt_thenItIsTheApprovedWording() {
        // given
        let gate = MainWindowGate.storeUnusable(StoreAttention(error: drawnRefusal))
        // when
        let copy = MainWindowGateView.copy(for: gate)
        // then
        #expect(copy == MainWindowGateView.Copy(
            title: "Task store needs attention",
            body: "Unsupported state root: foreign store marker; inspect state or select a fresh state root",
            status: nil,
            rows: [RuntimeGateDetailRow(label: "State root", value: "/Users/me/Library/Application Support/Harflow/State"),
                   RuntimeGateDetailRow(label: "Reason", value: "foreign_store")],
            actionTitle: "Open Settings", opensSettings: true))
    }

    @Test func givenAStoreRefusalWithoutAReason_whenCopyIsBuilt_thenTheCodeRowReplacesTheReasonRow() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Store refused.", data: [:])
        // when
        let copy = MainWindowGateView.copy(for: .storeUnusable(StoreAttention(error: error)))
        // then
        #expect(copy.rows == [RuntimeGateDetailRow(label: "Code", value: "state_incompatible")])
        #expect(copy.title == "Task store needs attention")
    }

    @Test(arguments: [("missing_root", "Task store has not been created"), ("recovery_interrupted", "Recovery was interrupted")])
    func givenARefusalReason_whenCopyIsBuilt_thenTheSettingsTitleShows(reason: String, title: String) {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Sentence", data: ["reason": .string(reason)])
        // when / then
        #expect(MainWindowGateView.copy(for: .storeUnusable(StoreAttention(error: error))).title == title)
    }

    @Test func givenEachGate_whenCopyIsBuilt_thenItIsTheApprovedWording() {
        // given
        let contract = MainWindowGate.contractRefused(status: "status line", code: nil)
        let contractWithCode = MainWindowGate.contractRefused(status: "status line", code: "incompatible_runtime")
        let capability = MainWindowGate.capabilityMissing(status: "status line", code: "incompatible_runtime")
        let noCode = MainWindowGate.capabilityMissing(status: "status line", code: nil)
        // when / then
        #expect(MainWindowGateView.copy(for: contract) == MainWindowGateView.Copy(
            title: "This Harflow runtime doesn't match the app",
            body: "Update the Harflow app to a version that matches this runtime.", status: "status line", rows: []))
        #expect(MainWindowGateView.copy(for: contractWithCode).rows == [RuntimeGateDetailRow(label: "Code", value: "incompatible_runtime")])
        #expect(MainWindowGateView.copy(for: capability) == MainWindowGateView.Copy(
            title: "This Harflow runtime is missing a feature the app needs",
            body: "Update the Harflow app to get a runtime that has it.", status: "status line",
            rows: [RuntimeGateDetailRow(label: "Code", value: "incompatible_runtime")]))
        #expect(MainWindowGateView.copy(for: noCode).rows.isEmpty)
    }

    // MARK: Loading error

    @Test func givenARefusalWithoutAReason_whenLoadingErrorIsBuilt_thenTheMessageHasNoCodeAndTheCodeIsSeparate() {
        // given
        let error = ToolError.refused(code: "state_incompatible", message: "Unsupported state root")
        // when
        let failure = LoadingWorkError(error: error)
        // then
        #expect(failure == LoadingWorkError(message: "Unsupported state root", code: "state_incompatible"))
    }

    @Test func givenARefusalWithAnEngineReason_whenLoadingErrorIsBuilt_thenNoCodeRowIsKept() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Foreign store",
                                                data: ["reason": .string("foreign_store")])
        // when
        let failure = LoadingWorkError(error: error)
        // then
        #expect(failure == LoadingWorkError(message: "Foreign store", code: nil))
    }

    @Test func givenAToolFailure_whenLoadingErrorIsBuilt_thenItKeepsTheMessageAndHasNoCode() {
        // given
        let error = ToolError.timedOut(tool: "harflow-ctl task-list-page", seconds: 30)
        // when / then
        #expect(LoadingWorkError(error: error) == LoadingWorkError(message: error.message, code: nil))
    }
}
