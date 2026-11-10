import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import SwiftUI
import Testing

// MARK: - TaskStopConfirmationHostedTests + TaskMount

extension TaskStopConfirmationHostedTests {
    @Test func givenMountedStandaloneTask_whenStopSheetOpensAndEscapes_thenTaskAndDraftStayMounted() async throws {
        // given
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone)
        let holder = TaskStopRequestHolder()
        let paneStore = TaskPaneStateStore()
        paneStore.setOpenChoice(.open, for: "abc12345")
        given(fixture.routing).presentStopConfirmation(.any).willProduce { holder.request = $0 }
        given(fixture.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .failed(.notFound(tool: "fixture changes", searched: []))))
        }
        fixture.detailBox.value = TaskDetailVMTests().task(liveInput: true)
        let page = RedesignHost(TaskStopMountHarness(sut: fixture.sut, holder: holder, paneStore: paneStore), size: CGSize(width: 1000, height: 700))
        defer { page.close(); fixture.sut.didDisappear() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([try #require(fixture.detailBox.value)])
        await page.settle { page.element("Stop") != nil && MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        await MessageBoxTranscriptStyleHostedTests.type("Retained task draft", into: field, in: page)
        // when
        #expect(page.press(try #require(page.element("Stop"))))
        await page.settle { page.window.attachedSheet != nil }
        let sheet = try #require(page.window.attachedSheet)
        // then
        #expect(fixture.sut.isMounted)
        #expect(fixture.sut.currentTaskID == "abc12345")
        #expect(holder.request?.taskID == "abc12345")
        #expect(field.window === page.window)
        #expect(paneStore.openChoice(for: "abc12345") == .open)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        await page.settle { page.window.attachedSheet == nil }
        #expect(fixture.sut.isMounted)
        #expect(field.stringValue == "Retained task draft")
        #expect(paneStore.openChoice(for: "abc12345") == .open)
        verify(fixture.useCase).cancel(.any).called(0)
    }
}

// MARK: - TaskStopRequestHolder

@Observable @MainActor private final class TaskStopRequestHolder {
    var request: TaskStopConfirmation?
}

// MARK: - TaskStopMountHarness

private struct TaskStopMountHarness: View {
    let sut: TaskDetailVM
    @Bindable var holder: TaskStopRequestHolder
    let paneStore: TaskPaneStateStore
    var body: some View {
        TaskDetailView(sut, chrome: .standalone, paneBinding: .init(store: paneStore, conversationID: "abc12345"), transcriptStyle: .transcript)
            .sheet(item: $holder.request) { request in
                TaskStopConfirmationView(confirmation: request) {
                    guard holder.request?.id == request.id else { return }
                    holder.request = nil
                    request.confirm()
                }
            }
    }
}
