@testable import HfRepository
import MonitorCore
import Testing

@Suite struct ToolErrorRefusalTests {

    @Test func givenARefusal_whenReadingItsParts_thenTheMessageCarriesNoCode() {
        // given
        let refused = ToolError.refused(code: "state_incompatible", message: "Unsupported state root.")
        let structured = ToolError.structuredRefusal(code: "state_incompatible", message: "Unsupported state root.", data: [:])

        // when / then
        for error in [refused, structured] {
            #expect(error.refusalMessage == "Unsupported state root.")
            #expect(error.displayMessage == "Unsupported state root.")
            #expect(error.message == "Unsupported state root. (state_incompatible)")
        }
    }

    @Test func givenARefusalWithAnEmptyMessage_whenReadingTheDisplayMessage_thenItReadsRefusedWithoutTheCode() {
        // given
        let error = ToolError.refused(code: "state_incompatible", message: "")

        // when / then
        #expect(error.refusalMessage == "")
        #expect(error.displayMessage == "Refused.")
    }

    @Test func givenANonRefusal_whenReadingItsParts_thenThereIsNoRefusalMessageAndTheDisplayMessageIsTheMessage() {
        // given
        let error = ToolError.timedOut(tool: "harflow-ctl", seconds: 8)

        // when / then
        #expect(error.refusalMessage == nil)
        #expect(error.displayMessage == "harflow-ctl did not answer within 8 s.")
    }
}
