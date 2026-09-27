import Foundation
import MonitorCore
@testable import PbRepository
import Testing

@Suite struct InstallCommandsTests {

    // MARK: firstGit

    @Test func givenNoGitOnPath_whenSearching_thenNilIsReturned() {
        // given
        let environment = ["PATH": "/usr/bin:/bin"]

        // when
        let result = InstallCommands.firstGit(onPath: environment, isExecutable: { _ in false })

        // then
        #expect(result == nil)
    }

    @Test func givenSeveralPathEntries_whenSearching_thenTheFirstExecutableGitWins() {
        // given — only the second directory actually has an executable `git`.
        let environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]

        // when
        let result = InstallCommands.firstGit(onPath: environment, isExecutable: { $0 == "/usr/bin/git" })

        // then
        #expect(result == "/usr/bin/git")
    }

    @Test func givenNoPathKey_whenSearching_thenNilIsReturned() {
        // given / when
        let result = InstallCommands.firstGit(onPath: [:], isExecutable: { _ in true })

        // then
        #expect(result == nil)
    }

    // MARK: installNeed classifier

    @Test func givenBothCtlAndSetupNotFound_whenClassifying_thenMissingIsReturned() {
        // given
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: [])

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .notFound, setup: .notFound)

        // then
        #expect(need == .missing)
    }

    @Test func givenSetupMissingButCtlPresent_whenClassifying_thenIncompleteIsReturned() {
        // given
        let error = ToolError.notFound(tool: "polybridge-setup", searched: [])

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .found(path: "/bin/polybridge-ctl"), setup: .notFound)

        // then
        #expect(need == .incomplete)
    }

    @Test func givenCtlMissingButSetupPresent_whenClassifying_thenIncompleteIsReturned() {
        // given
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: [])

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .notFound, setup: .found(path: "/bin/polybridge-setup"))

        // then
        #expect(need == .incomplete)
    }

    @Test func givenBothPresentButAnUnsupportedCommand_whenClassifying_thenIncompleteIsReturned() {
        // given — an old install both binaries exist for, but this particular subcommand predates it.
        let error = ToolError.unsupportedCommand(tool: "polybridge-ctl", command: "status", detail: "invalid choice")

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .found(path: "/bin/polybridge-ctl"), setup: .found(path: "/bin/polybridge-setup"))

        // then
        #expect(need == .incomplete)
    }

    @Test func givenBothPresentAndOrdinaryNotFound_whenClassifying_thenNilIsReturned() {
        // given — contradictory in practice, but the classifier only reasons from what it's given:
        // both being present but this call reporting `.notFound` doesn't fall into `.missing` or
        // `.incomplete`.
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: [])

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .found(path: "/bin/polybridge-ctl"), setup: .found(path: "/bin/polybridge-setup"))

        // then
        #expect(need == nil)
    }

    @Test func givenANonPolybridgeToolNotFound_whenClassifying_thenNilIsReturned() {
        // given
        let error = ToolError.notFound(tool: "git", searched: [])

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .notFound, setup: .notFound)

        // then
        #expect(need == nil)
    }

    @Test func givenAGitLaunchFailure_whenClassifying_thenNilIsReturned() {
        // given — every non-notFound/unsupportedCommand `ToolError` keeps its own existing message.
        let error = ToolError.launchFailed(tool: "git", detail: "no such file")

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .notFound, setup: .notFound)

        // then
        #expect(need == nil)
    }

    @Test func givenAnUnsupportedVersion_whenClassifying_thenNilIsReturned() {
        // given
        let error = ToolError.unsupportedVersion(tool: "polybridge-ctl", version: "3")

        // when
        let need = InstallCommands.installNeed(for: error, ctl: .found(path: "/bin/polybridge-ctl"), setup: .found(path: "/bin/polybridge-setup"))

        // then
        #expect(need == nil)
    }
}
