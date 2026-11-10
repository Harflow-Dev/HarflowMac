import AppKit
import Combine
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStoppingHostedTests + Acknowledgement

extension TaskStoppingHostedTests {
    @Test func givenConfirmedStop_whenFreshReadCompletes_thenRealRepositoriesQualifyMountedStopping() async throws {
        // given — the synchronous mock bridge retains the real async cancel task for this hosted test.
        let runner = StoppingCtlRunner()
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fixture/harflow-ctl", environment: [:], runner: runner)))
        let snapshots = TaskSnapshotRepositoryImpl(toolEnvironment: environment)
        await snapshots.refresh("abc12345")
        let running = try #require(snapshots.snapshot("abc12345"))
        let list = MockTaskListRepository()
        given(list).tasks.willReturn([running])
        given(list).tasksPublisher().willReturn(Just([running]).eraseToAnyPublisher())
        given(list).refresh().willReturn()
        let actions = TaskActionRepositoryImpl(toolEnvironment: environment, taskListRepository: list, snapshotRepository: snapshots)
        let fixtures = TaskDetailVMTests.Fixtures()
        fixtures.stoppingQuery.value = { actions.isStopping($0) }
        fixtures.stoppingPublisher.value = actions.stoppingChangesPublisher()
        let cancelTask = TaskDetailVMTests.Box<Task<Void, Never>?>(nil)
        fixtures.cancelEffect.value = { id in
            cancelTask.value = Task { _ = try? await actions.cancel(id) }
            return true
        }
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        fixture.detailBox.value = running
        fixture.snapshotBox.value = running
        let confirmation = StoppingConfirmationState()
        given(fixture.routing).presentStopConfirmation(.any).willProduce { confirmation.request = $0 }
        let page = RedesignHost(StoppingConfirmationHarness(sut: fixture.sut, confirmation: confirmation), size: CGSize(width: 1000, height: 700))
        defer { page.close(); fixture.sut.didDisappear(); cancelTask.value?.cancel() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { fixture.sut.isMounted }
        fixture.tasksSubject.send([running])
        await page.settle { page.element("Stop") != nil }
        // when — the public cancel acknowledgement precedes the parked post-ack status read.
        #expect(page.press(try #require(page.element("Stop"))))
        await page.settle { page.window.attachedSheet != nil }
        let root = try #require(page.window.attachedSheet?.contentView)
        let confirm = try #require(page.elements(in: root).first { page.matches($0, "Stop task") })
        #expect(page.press(confirm))
        await page.settle { runner.parked.value }
        #expect(runner.parked.value)
        #expect(!actions.isStopping("abc12345"))
        #expect(page.element("Stop requested") == nil)
        await runner.releaseStatus()
        await cancelTask.value?.value
        // then
        await page.settle { page.element("Stopping…") != nil && page.element("Stop requested") != nil }
        #expect(actions.isStopping("abc12345"))
        #expect(fixture.sut.isStopping)
        #expect(Self.isEnabled(try #require(page.element("Stopping…"))) == false)
    }
}

@Observable @MainActor private final class StoppingConfirmationState {
    var request: TaskStopConfirmation?
}

private struct StoppingConfirmationHarness: View {
    @State var sut: TaskDetailVM
    @Bindable var confirmation: StoppingConfirmationState
    var body: some View {
        TaskDetailView(sut, chrome: .standalone, transcriptStyle: .transcript)
            .sheet(item: $confirmation.request) { request in
                TaskStopConfirmationView(confirmation: request) {
                    guard confirmation.request?.id == request.id else { return }
                    confirmation.request = nil
                    request.confirm()
                }
            }
    }
}

private actor StoppingCtlRunner: ProcessRunning {
    nonisolated let parked = StoppingReadFlag()
    private var statusCount = 0
    private var statusContinuation: CheckedContinuation<Void, Never>?

    func releaseStatus() {
        statusContinuation?.resume()
        statusContinuation = nil
    }

    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        let document: String
        switch arguments.first {
        case "version-info":
            let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
            document = "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},\"setup\":{\"format\":\"harflow.setup\",\"v\":1}," +
                "\"events\":{\"format\":\"harflow.event\",\"v\":1}},\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"]," +
                "\"os\":\"darwin\",\"architecture\":\"arm64\"}"
        case "cancel":
            document = envelope(#""result":{"task_id":"abc12345","status":"cancelled"}"#)
        case "status":
            statusCount += 1
            if statusCount > 1 {
                await withCheckedContinuation { continuation in
                    statusContinuation = continuation
                    parked.value = true
                }
            }
            document = envelope(#""task":{"task_id":"abc12345","backend":"claude","status":"running","live_input":true,"supervision":{"owner_state":"alive"}}"#)
        default: return .failure(.unsupportedCommand(tool: "fixture", command: arguments.first ?? "", detail: "Unexpected fixture command"))
        }
        return .success(ProcessOutput(exitCode: 0, stdout: Data(document.utf8), stderr: ""))
    }

    private func envelope(_ field: String) -> String {
        #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1",\#(field)}"#
    }
}

private final class StoppingReadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
