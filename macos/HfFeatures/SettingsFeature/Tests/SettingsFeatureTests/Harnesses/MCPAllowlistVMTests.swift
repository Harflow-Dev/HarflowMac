import Combine
import HfCommon
import HfCommonTestMock
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct MCPAllowlistVMTests {
    private func waitForDialog(_ sut: MCPAllowlistVM, publish: () -> Void) async -> (AlertContent, AnyCancellable) {
        var published: AlertContent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { event in
            if case .dialog(let dialog) = event { published = dialog }
        }
        publish()
        await waitUntil { published != nil }
        return (published!, cancellable)
    }

    @Test func givenSupportedBackend_whenLoaded_thenEntriesAndScopeAreVisible() async throws {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase).request(backend: .value("claude"), allow: .value(nil), remove: .value(nil)).willReturn([
            "supported": .bool(true), "entries": .array([.string("harflow/*")]), "config_path": .string("/test/settings.json")
        ])
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude", useCase: useCase)
        // when
        await vm.load()
        vm.entry = "harflow/apply_workflow_draft"
        // then
        #expect(vm.entries == ["harflow/*"])
        #expect(vm.configPath == "/test/settings.json")
        #expect(vm.canAdd)
    }

    @Test func givenUnsupportedBackend_whenLoaded_thenMutationsStayDisabled() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase).request(backend: .any, allow: .any, remove: .any).willReturn(["supported": .bool(false), "detail": .string("Not supported")])
        let vm = MCPAllowlistVM(backend: "unknown", title: "Unknown", useCase: useCase)
        // when
        await vm.load()
        vm.entry = "server/*"
        // then
        #expect(!vm.canAdd)
        #expect(vm.detail == "Not supported")
    }

    @Test func givenApproval_whenConfirmed_thenOnlyCapturedEntryIsSent() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase).request(backend: .any, allow: .any, remove: .any).willReturn(["supported": .bool(true)])
        let vm = MCPAllowlistVM(backend: "codex", title: "Codex", useCase: useCase)
        await vm.load()
        vm.entry = "harflow/*"
        // when
        let (dialog, cancellable) = await waitForDialog(vm) { vm.confirmAdd() }
        vm.entry = "different/tool"
        dialog.actions.first?.action()
        await waitUntil { vm.entry.isEmpty }
        // then
        verify(useCase).request(backend: .value("codex"), allow: .value("harflow/*"), remove: .value(nil)).called(1)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenVibe_whenEnteringWildcard_thenOnlyExactToolCanBeApproved() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase).request(backend: .any, allow: .any, remove: .any).willReturn(["supported": .bool(true)])
        let vm = MCPAllowlistVM(backend: "vibe", title: "Vibe", useCase: useCase)
        await vm.load()
        // when / then
        vm.entry = "harflow/*"
        #expect(!vm.canAdd)
        #expect(vm.entryPlaceholder == "server/tool")
        vm.entry = "harflow/apply_workflow_draft"
        #expect(vm.canAdd)
        let (dialog, cancellable) = await waitForDialog(vm) { vm.confirmAdd() }
        #expect(dialog.description?.contains("only the named tool") == true)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenMalformedEntry_whenValidated_thenRejected() {
        // given / when / then
        for value in ["", "server", "/tool", "server/", "server/tool/extra", "server/white space"] {
            #expect(!MCPAllowlistVM.validEntry(value))
        }
        #expect(MCPAllowlistVM.backend(for: "claude-code") == "claude")
    }

    // MARK: - States

    private func loadedVM(
        backend: String = "claude", entries: [String] = ["harflow/*"], useCase: MockMCPAllowlistUseCase = MockMCPAllowlistUseCase()
    ) async -> MCPAllowlistVM {
        given(useCase).request(backend: .any, allow: .value(nil), remove: .value(nil)).willReturn([
            "supported": .bool(true), "entries": .array(entries.map(JSONValue.string)),
            "config_path": .string("/test/settings.json"), "detail": .string("Global rules apply.")
        ])
        let vm = MCPAllowlistVM(backend: backend, title: "Claude Code", useCase: useCase)
        await vm.load()
        return vm
    }

    @Test func givenEmptyEntries_whenLoaded_thenEmptyLineShows() async {
        // given / when
        let vm = await loadedVM(entries: [])
        // then
        #expect(vm.showsEmpty)
        #expect(vm.fieldEnabled)
        #expect(vm.errorMessage == nil)
    }

    @Test func givenEntries_whenLoaded_thenEmptyLineHidden() async {
        // given / when
        let vm = await loadedVM()
        // then
        #expect(!vm.showsEmpty)
    }

    @Test func givenUnsupportedHarness_whenLoaded_thenFieldDisabledAndEmptyLineHidden() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase).request(backend: .any, allow: .any, remove: .any).willReturn([
            "supported": .bool(false), "config_path": .string("~/.cursor/mcp.json"), "detail": .string("Per project directory.")
        ])
        let vm = MCPAllowlistVM(backend: "cursor", title: "Cursor", useCase: useCase)
        // when
        await vm.load()
        // then
        #expect(!vm.fieldEnabled)
        #expect(!vm.showsEmpty)
        #expect(vm.configPath == "~/.cursor/mcp.json")
        #expect(vm.detail == "Per project directory.")
    }

    @Test func givenUnsupportedCommand_whenLoaded_thenMissingFeatureSentenceAndFieldDisabledAndNoPath() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase)
.request(backend: .any, allow: .any, remove: .any)
            .willThrow(ToolError.unsupportedCommand(tool: "harflow-ctl", command: "mcp-allowlist", detail: "usage"))
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude Code", useCase: useCase)
        // when
        await vm.load()
        // then
        #expect(vm.missingFeatureSentence == "This Harflow runtime can't edit global MCP approvals. Update Harflow to use it.")
        #expect(vm.errorMessage == nil)
        #expect(vm.errorCode == nil)
        #expect(!vm.fieldEnabled)
        #expect(vm.configPath.isEmpty)
        #expect(vm.detail.isEmpty)
        #expect(!vm.showsEmpty)
    }

    @Test func givenUnsupportedCommandForAnotherCommand_whenLoaded_thenToolMessageShowsNotTheSentence() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "status", detail: "usage")
        given(useCase).request(backend: .any, allow: .any, remove: .any).willThrow(error)
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude Code", useCase: useCase)
        // when
        await vm.load()
        // then
        #expect(vm.missingFeatureSentence == nil)
        #expect(vm.errorMessage == error.displayMessage)
    }

    @Test func givenUnreadableRead_whenLoaded_thenErrorWithoutCodeAndEntriesCleared() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        var failing = false
        given(useCase).request(backend: .any, allow: .value(nil), remove: .value(nil)).willProduce { _, _, _ in
            if failing { throw ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "") }
            return ["supported": .bool(true), "entries": .array([.string("harflow/*")]),
                    "config_path": .string("/test/settings.json"), "detail": .string("Global rules apply.")]
        }
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude Code", useCase: useCase)
        await vm.load()
        failing = true
        // when
        await vm.load()
        // then
        #expect(vm.errorMessage == "harflow-ctl exited 1 without a JSON answer.")
        #expect(vm.errorCode == nil)
        #expect(!vm.supported)
        #expect(vm.entries.isEmpty)
        #expect(vm.configPath.isEmpty)
        #expect(vm.detail.isEmpty)
        #expect(!vm.fieldEnabled)
        #expect(!vm.showsEmpty)
    }

    @Test func givenAllowlistErrorOnAllow_whenConfirmed_thenMessageWithoutCodeCodeLineAndEntriesAndTypedValueKept() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        let vm = await loadedVM(useCase: useCase)
        given(useCase)
.request(backend: .any, allow: .value("github/get_issue"), remove: .value(nil))
            .willThrow(ToolError.refused(code: "allowlist_error", message: "Harness configuration changed; reload and try again"))
        vm.entry = "github/get_issue"
        // when
        let (dialog, cancellable) = await waitForDialog(vm) { vm.confirmAdd() }
        dialog.actions.first?.action()
        await waitUntil { vm.errorMessage != nil }
        // then
        #expect(vm.errorMessage == "Harness configuration changed; reload and try again")
        #expect(vm.errorCode == "allowlist_error")
        #expect(vm.entries == ["harflow/*"])
        #expect(vm.configPath == "/test/settings.json")
        #expect(vm.detail == "Global rules apply.")
        #expect(vm.entry == "github/get_issue")
        #expect(vm.supported)
        #expect(vm.fieldEnabled)
        #expect(vm.actionsEnabled)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenHumanOnlyOnRemove_whenConfirmed_thenCodeIsHumanOnlyAndEntriesKept() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        let vm = await loadedVM(useCase: useCase)
        let reason = "Only a verified human may change global MCP approval rules: it was called from task 4f2a91c0"
        given(useCase)
.request(backend: .any, allow: .value(nil), remove: .value("harflow/*"))
            .willThrow(ToolError.refused(code: "human_only", message: reason))
        // when
        let (dialog, cancellable) = await waitForDialog(vm) { vm.confirmRemove("harflow/*") }
        dialog.actions.first?.action()
        await waitUntil { vm.errorCode != nil }
        // then
        #expect(vm.errorCode == "human_only")
        #expect(vm.errorMessage == reason)
        #expect(vm.entries == ["harflow/*"])
        #expect(vm.supported)
        #expect(vm.fieldEnabled)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenAnErrorThenSuccess_whenRefreshed_thenErrorCodeAndSentenceClear() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        var failing = true
        given(useCase).request(backend: .any, allow: .value(nil), remove: .value(nil)).willProduce { _, _, _ in
            if failing { throw ToolError.refused(code: "allowlist_error", message: "Harness configuration changed; reload and try again") }
            return ["supported": .bool(true), "entries": .array([.string("harflow/*")])]
        }
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude Code", useCase: useCase)
        await vm.load()
        #expect(vm.errorCode == "allowlist_error")
        failing = false
        // when
        await vm.load()
        // then
        #expect(vm.errorMessage == nil)
        #expect(vm.errorCode == nil)
        #expect(vm.missingFeatureSentence == nil)
        #expect(vm.entries == ["harflow/*"])
        #expect(vm.fieldEnabled)
    }

    @Test func givenUnsupportedCommandThenSuccess_whenRefreshed_thenMissingFeatureSentenceClears() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        var failing = true
        given(useCase).request(backend: .any, allow: .value(nil), remove: .value(nil)).willProduce { _, _, _ in
            if failing { throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "mcp-allowlist", detail: "usage") }
            return ["supported": .bool(true), "entries": .array([.string("harflow/*")])]
        }
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude Code", useCase: useCase)
        await vm.load()
        #expect(vm.missingFeatureSentence != nil)
        failing = false
        // when
        await vm.load()
        // then
        #expect(vm.missingFeatureSentence == nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.entries == ["harflow/*"])
        #expect(vm.fieldEnabled)
    }

    @Test func givenFirstReadNotAnswered_whenEntryTyped_thenAddStaysDisabled() {
        // given
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude Code", useCase: MockMCPAllowlistUseCase())
        // when
        vm.entry = "harflow/*"
        // then
        #expect(!vm.fieldEnabled)
        #expect(!vm.canAdd)
    }
}
