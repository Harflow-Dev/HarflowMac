import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - SidebarPollingLayoutTests

@MainActor @Suite(.serialized) struct SidebarPollingLayoutTests {
    @Test(arguments: [false, true], [0.0, 100.0])
    func givenLoadedLargeWorkflow_whenIdenticalPollsAndClockUpdateArrive_thenSidebarGeometryAndScrollStayStable(
        emitRecovery: Bool, scrollOffset: Double
    ) async throws {
        // given
        _ = NSApplication.shared
        let helpers = SidebarVMTests()
        let harness = helpers.makeSUT()
        let tasks = fixtureTasks(helpers)
        let workflow = WorkflowPreview.make(run: true)
        let raw = cancelledRun(try #require(workflow.selectedRun?.raw))
        workflow.selectedRun = WorkflowRunModel(raw: raw)
        harness.sut.workflowRuns = [SidebarWorkflowRun(raw: raw)]
        harness.routingSelectionBox.value = .workflowRun("polling-layout")
        let host = NSHostingView(rootView: NavigationSplitView {
            SidebarView(harness.sut).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: { WorkflowView(workflow) }.frame(minWidth: 1000, minHeight: 620).withPresentationContext())
        let window = makeWindow(host)
        defer { harness.sut.didDisappear(); window.contentView = nil; window.close() }
        harness.sut.didAppear()
        harness.hasListedSubject.send(true)
        harness.tasksSubject.send(tasks)
        await waitUntil { host.layoutSubtreeIfNeeded(); return harness.sut.sections.flatMap(\.items).count == 29 }
        workflow.didDisappear()
        workflow.selectedRun = WorkflowRunModel(raw: raw)
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        let search = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search loaded history" })
        let scroll = try #require(outline.enclosingScrollView)
        await waitUntil { host.layoutSubtreeIfNeeded(); return outline.numberOfRows > 25 && outline.rect(ofRow: 2).height > 20 }
        await waitForStableLayout(host: host, search: search, outline: outline, scroll: scroll)
        #expect(scroll.contentInsets.top == 0)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scrollOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitForStableLayout(host: host, search: search, outline: outline, scroll: scroll)
        let baseline = sample(host: host, search: search, outline: outline, scroll: scroll)
        let recorder = SidebarGeometryRecorder { sample(host: host, search: search, outline: outline, scroll: scroll) }
        recorder.start(search: search, outline: outline, clip: scroll.contentView)
        defer { recorder.stop() }
        // when — layout passes are sampled individually, including intermediate publications.
        for poll in 0 ..< 16 {
            let elapsed: Double = poll < 8 ? 61 : Double(62 + poll)
            let update = [helpers.task(id: "running-clock", startedAt: nil, durationSeconds: elapsed)] + Array(tasks.dropFirst())
            harness.tasksSubject.send(update)
            await waitUntil { clockDuration(harness.sut) == elapsed }
            harness.sut.mergeWorkflowHeaders([raw])
            harness.sut.recompute()
            publishRecoveries(harness.sut, enabled: emitRecovery)
            for _ in 0 ..< 4 {
                await Task.yield()
                pumpLayout(host)
                // then
                #expect(sample(host: host, search: search, outline: outline, scroll: scroll) == baseline)
                #expect(harness.sut.selection == .workflowRun("polling-layout"))
                #expect(workflow.selectedRun?.status == "cancelled")
            }
        }
        // when — changing the supplied elapsed clock must still refresh the row.
        let updated = [helpers.task(id: "running-clock", startedAt: nil, durationSeconds: 62)] + Array(tasks.dropFirst())
        harness.tasksSubject.send(updated)
        await waitUntil { host.layoutSubtreeIfNeeded(); return clockDuration(harness.sut) == 62 }
        await sampleTimerTicks(host: host, recorder: recorder)
        // then
        #expect(sample(host: host, search: search, outline: outline, scroll: scroll) == baseline)
        #expect(clockDuration(harness.sut) == 62)
        #expect(harness.sut.selection == .workflowRun("polling-layout"))
        #expect(recorder.samples.allSatisfy { $0 == baseline }, "Native geometry callbacks must not capture a temporary jump")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func pumpLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        host.displayIfNeeded()
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1512, height: 950),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "Sidebar polling fixture")
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1512, height: 950)
        window.orderFront(nil)
        return window
    }

    private func clockDuration(_ vm: SidebarVM) -> Double? {
        vm.runningRows.first { $0.id == "running-clock" }?.durationSeconds
    }

    private func publishRecoveries(_ vm: SidebarVM, enabled: Bool) {
        guard enabled else { return }
        vm.publishViewEvent(.incidentResolved(source: "workflow-list"))
        vm.publishViewEvent(.incidentResolved(source: "workflow-status"))
    }

    private func fixtureTasks(_ helpers: SidebarVMTests) -> [TaskInfo] {
        [helpers.task(id: "running-clock", startedAt: nil, durationSeconds: 61),
         helpers.task(id: "timer-clock", startedAt: .now.addingTimeInterval(-100))]
            + (0 ..< 3).map { helpers.task(id: "group-\($0)", group: "Collapsed parallel group") }
            + (0 ..< 25).map { helpers.task(id: "history-\($0)", status: "completed") }
    }

    private func sampleTimerTicks(host: NSView, recorder: SidebarGeometryRecorder) async {
        let until = Date().addingTimeInterval(2.1)
        await waitUntil {
            pumpLayout(host)
            recorder.record()
            return Date() >= until
        }
    }

    private func waitForStableLayout(host: NSView, search: NSView, outline: NSOutlineView, scroll: NSScrollView) async {
        var previous: [CGRect] = []
        var stablePasses = 0
        await waitUntil {
            pumpLayout(host)
            let current = sample(host: host, search: search, outline: outline, scroll: scroll)
            stablePasses = current == previous ? stablePasses + 1 : 0
            previous = current
            return stablePasses >= 6
        }
    }

    private func cancelledRun(_ original: [String: JSONValue]) -> [String: JSONValue] {
        var raw = original
        raw["workflow_run_id"] = .string("polling-layout")
        raw["status"] = .string("cancelled")
        raw["prompt"] = .string(String(repeating: "A long multi-platform specification.\n", count: 30))
        raw["tasks"] = .array((0 ..< 19).map { .object(["id": .string("plan-\($0)"), "title": .string("Checklist \($0)")]) })
        return raw
    }

    private func sample(host: NSView, search: NSView, outline: NSOutlineView, scroll: NSScrollView) -> [CGRect] {
        let insets = scroll.contentInsets
        return [host.convert(search.bounds, from: search), search.convert(search.bounds, to: nil),
                scroll.convert(scroll.bounds, to: nil), scroll.contentView.convert(scroll.contentView.bounds, to: nil),
                scroll.contentView.bounds, CGRect(x: insets.left, y: insets.top, width: insets.right, height: insets.bottom)]
            + (0 ..< outline.numberOfRows).map { outline.rect(ofRow: $0) }
    }
}

// MARK: - SidebarGeometryRecorder

@MainActor private final class SidebarGeometryRecorder {
    let read: () -> [CGRect]
    var samples: [[CGRect]] = []
    var callbackCount = 0
    private var tokens: [NSObjectProtocol] = []

    init(read: @escaping () -> [CGRect]) { self.read = read }

    func start(search: NSView, outline: NSOutlineView, clip: NSClipView) {
        enableNotifications(outline)
        search.postsFrameChangedNotifications = true
        clip.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let view = event.object as? NSView else { return }
                MainActor.assumeIsolated {
                    guard view === search || view === clip || view.isDescendant(of: outline) else { return }
                    self?.callbackCount += 1
                    self?.record()
                }
            })
        }
    }

    func record() { samples.append(read()) }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    private func enableNotifications(_ view: NSView) {
        view.postsFrameChangedNotifications = true
        view.postsBoundsChangedNotifications = true
        view.subviews.forEach(enableNotifications)
    }
}
