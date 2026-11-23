@testable import HfRepository
import Testing

@Suite
struct RuntimeSetupStateTests {
    private static let cases: [(RuntimeSetupState, title: String, detail: String, action: String?)] = [
        (.checking, "Checking Harflow runtime…", "Checking the managed installation on this Mac.", nil),
        (.installationRequired(installedVersion: nil, requiredVersion: "0.0.8"), "Prepare Harflow",
         "Install the components Harflow needs to run. Required runtime: 0.0.8.", "Install required components"),
        (.installationRequired(installedVersion: "0.0.7", requiredVersion: "0.0.8"), "Update Harflow runtime",
         "Installed runtime 0.0.7. This app requires runtime 0.0.8.", "Update required components"),
        (.installing, "Preparing Harflow…", "Installing required components for this app.", nil),
        (.updating(installedVersion: "0.0.7", requiredVersion: "0.0.8"), "Updating Harflow…",
         "Installing the update from runtime 0.0.7 to 0.0.8. Your task history is preserved during the update.", nil),
        (.updateFailed(message: "Package verification failed.", installedVersion: "0.0.7", requiredVersion: "0.0.8"),
         "Update did not finish",
         "Installed runtime 0.0.7; required runtime 0.0.8. Your history and existing installation have been kept. "
             + "Package verification failed.", "Retry update"),
        (.failed("Package verification failed."), "Setup did not finish", "Package verification failed.", "Retry installation"),
        (.ready, "Harflow runtime is ready", "MCP registrations are managed separately in Harnesses.", nil)
    ]

    @Test
    func givenEachRuntimeSetupState_whenCopyIsRead_thenItMatchesTheApprovedRuntimeWording() {
        for (state, title, detail, action) in Self.cases {
            // given / when / then
            #expect(state.title == title)
            #expect(state.detail == detail)
            #expect(state.actionTitle == action)
        }
    }
}
