import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct MainWindowGateSidebarAndCopyTests {
    private let drawnRefusal = ToolError.structuredRefusal(
        code: "state_incompatible",
        message: "Unsupported state root: foreign store marker; inspect state or select a fresh state root",
        data: ["reason": .string("foreign_store"), "state_root": .string("/Users/me/Library/Application Support/Harflow/State")]
    )

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
}
