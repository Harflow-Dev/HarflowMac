import Foundation
@testable import MonitorCore
import Testing

@Suite(.serialized)
struct CtlMutationCancellationTests {
    @Test
    func givenOperationSupersededDuringLaunchedMutation_whenCommandCompletes_thenSuccessfulResultIsPreserved() async throws {
        // given — the mutation starts while current; the owner is superseded while ctl is running.
        let runner = compatibleRunner { _ in
            ProcessOutput(
                exitCode: 0,
                stdout: ctlJSON(#"{"v":2,"result":{"status":"cancelled"}}"#),
                stderr: ""
            )
        }
        var client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)
        client.operationIsCurrent = { runner.calls.isEmpty }

        // when
        let result = await client.cancel("t1")

        // then — operationIsCurrent is false after the runner records cancel, but ctl's actual
        // successful mutation response remains authoritative once the command has launched.
        try #expect(try result.get()["status"] == .string("cancelled"))
        #expect(runner.calls.map(\.arguments) == [["cancel", "--json", "--", "t1"]])
    }
}
