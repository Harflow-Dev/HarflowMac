import Combine
import Mockable
import MonitorCore
import PbCommon
import PbCommonTestMock
import PbTestUtilities
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
            "supported": .bool(true), "entries": .array([.string("polybridge/*")]), "config_path": .string("/test/settings.json")
        ])
        let vm = MCPAllowlistVM(backend: "claude", title: "Claude", useCase: useCase)
        // when
        await vm.load()
        vm.entry = "polybridge/apply_workflow_draft"
        // then
        #expect(vm.entries == ["polybridge/*"])
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
        vm.entry = "polybridge/*"
        // when
        let (dialog, cancellable) = await waitForDialog(vm) { vm.confirmAdd() }
        vm.entry = "different/tool"
        dialog.actions.first?.action()
        await waitUntil { vm.entry.isEmpty }
        // then
        verify(useCase).request(backend: .value("codex"), allow: .value("polybridge/*"), remove: .value(nil)).called(1)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenVibe_whenEnteringWildcard_thenOnlyExactToolCanBeApproved() async {
        // given
        let useCase = MockMCPAllowlistUseCase()
        given(useCase).request(backend: .any, allow: .any, remove: .any).willReturn(["supported": .bool(true)])
        let vm = MCPAllowlistVM(backend: "vibe", title: "Vibe", useCase: useCase)
        await vm.load()
        // when / then
        vm.entry = "polybridge/*"
        #expect(!vm.canAdd)
        #expect(vm.entryPlaceholder == "server/tool")
        vm.entry = "polybridge/apply_workflow_draft"
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
}
