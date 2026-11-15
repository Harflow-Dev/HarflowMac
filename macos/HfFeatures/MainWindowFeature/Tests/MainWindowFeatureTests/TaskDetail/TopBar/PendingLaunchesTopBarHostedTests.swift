import AppKit
import Combine
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - HostedUseCase

/// A pending launches use case with one stored answer per check: a qualified lookup, or a check that stays open so the
/// selection has no stored lookup yet (the copy-free checking placeholder).
@MainActor
private final class HostedUseCase: PendingLaunchesUseCase {
    let subject: CurrentValueSubject<PendingLaunchSnapshot, Never>
    let lease = PendingLaunchReadLease()
    var holdsChecks: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(rows: [TaskPendingLaunchItem], holdsChecks: Bool) {
        self.subject = CurrentValueSubject(.init(inventory: .init(rows: rows, completedCheck: true)))
        self.holdsChecks = holdsChecks
    }

    var snapshot: PendingLaunchSnapshot { subject.value }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { subject.eraseToAnyPublisher() }
    func acquireReadLease() -> PendingLaunchReadLease? { lease }
    func releaseReadLease(_: PendingLaunchReadLease) {}
    func refresh(lease _: PendingLaunchReadLease) async {}
    func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection? {
        taskID.map { PendingLaunchSelection(taskID: $0, lease: lease) }
    }

    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup {
        if holdsChecks { await withCheckedContinuation { waiting.append($0) } }
        let item = subject.value.inventory.rows.first { $0.taskID == selection.taskID }
        let lookup = PendingLaunchLookup(selection: selection, value: item.map(PendingLaunchesFixture.lookup), failure: item == nil ? .unavailable : nil)
        var next = subject.value
        next.lookups = next.lookups.filter { $0.selection.lease != lookup.selection.lease } + [lookup]
        subject.send(next)
        return lookup
    }

    func resolveRecorded(selection _: PendingLaunchSelection) async -> PendingLaunchRecordedResult { .failed(.unavailable) }
    func prepareStop(selection _: PendingLaunchSelection) async -> PendingLaunchStopPreparation { .failed(.unavailable) }
    func submitStop(confirmation _: PendingLaunchStopConfirmation) -> PendingLaunchStopAdmission { .refused(.unavailable) }

    /// Lets held checks finish, so no task outlives the test.
    func releaseHeld() {
        holdsChecks = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
}

// MARK: - TopBarAdapter

/// What the coordinator does for the pending page: forwards the VM's top bar writes to the holder.
@MainActor
private final class TopBarAdapter: PendingLaunchesTopBarRouting {
    let holder: TaskTopBarHolder
    init(_ holder: TaskTopBarHolder) { self.holder = holder }
    func publishTopBar(_ content: PageTopBarContent, tag: TaskTopBarHolder.Tag) { holder.publish(content, tag: tag) }
    func clearTopBar(tag: TaskTopBarHolder.Tag) { holder.clear(tag: tag) }
    func activateTopBar(tag: TaskTopBarHolder.Tag) { holder.activate(tag) }
    func deactivateTopBar(tag: TaskTopBarHolder.Tag) { holder.deactivate(tag) }
    func retryTopBarActivation(tag: TaskTopBarHolder.Tag) { holder.activateIfVacant(tag) }
}

// MARK: - PendingLaunchesTopBarHostedTests

/// The Pending launches page in the production shell with its real view model: the window's principal item draws the
/// page title and the "Pending launch" badge the VM publishes for the screen shown (HarflowDesign `83d820f`,
/// `v2/scripts/screens-pending-launches.js` `render()`). With `HARFLOW_PENDING_TOPBAR_CAPTURE_DIR` set it also writes
/// window captures of the inventory, a qualified detail and the checking detail, light and dark at both approved sizes.
@MainActor @Suite(.serialized) struct PendingLaunchesTopBarHostedTests {
    static let captureKey = "HARFLOW_PENDING_TOPBAR_CAPTURE_DIR"
    private static let designCommit = "83d820f57e6ec2d82cccd3a1e335128332fdb672"
    private static let designFile = "v2/scripts/screens-pending-launches.js"
    private static let launchID = "20261110-093000-a17c92"

    enum Scenario: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case inventory, qualifiedDetail = "qualified-detail", checking

        var testDescription: String { rawValue }

        /// The title the VM publishes for the screen shown.
        var title: String {
            switch self {
            case .inventory: "Pending launches"
            case .qualifiedDetail: "Review launch admission checks"
            case .checking: "Pending launch"
            }
        }

        /// A line only this screen's detail card draws.
        var bodyLine: String {
            switch self {
            case .inventory: ""
            case .qualifiedDetail: "Waiting for resources"
            case .checking: "Checking launch status"
            }
        }

        /// The design route the state is built against. The design draws no separate checking state, so it names its
        /// unavailable detail, whose title is the same neutral "Pending launch".
        var route: String {
            switch self {
            case .inventory: "#task/pending-inventory"
            case .qualifiedDetail: "#task/pending-waiting"
            case .checking: "#task/pending-unavailable"
            }
        }
    }

    @MainActor private struct Shell {
        let window: NSWindow
        let coordinator: MainWindowNavigationCoordinatorMock
        let vm: PendingLaunchesVM?
        fileprivate let useCase: HostedUseCase?
        fileprivate let adapter: TopBarAdapter?
        func close() {
            useCase?.releaseHeld()
            vm?.didDisappear()
            window.contentViewController = nil
            window.close()
        }
    }

    private func pump(_ window: NSWindow, passes count: Int) async {
        var passes = 0
        await waitUntil(timeout: 10) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= count
        }
    }

    /// The shell around the real pending launches screen, driven to `scenario` through the VM's own selection path. With no
    /// scenario the page's writer is absent (the first frame).
    private func shell(_ scenario: Scenario?, size: CGSize, dark: Bool = false) async -> Shell {
        _ = NSApplication.shared
        let coordinator = MainWindowNavigationCoordinatorMock()
        coordinator.selection = .pendingLaunches
        coordinator.topBar.setShownSubject(.pendingLaunches)
        var vm: PendingLaunchesVM?
        var useCase: HostedUseCase?
        var adapter: TopBarAdapter?
        if let scenario {
            let hosted = HostedUseCase(rows: PendingLaunchesFixture.items, holdsChecks: scenario == .checking)
            let router = TopBarAdapter(coordinator.topBar)
            let model = PendingLaunchesVM(useCase: hosted, topBarRouting: router)
            (vm, useCase, adapter) = (model, hosted, router)
            coordinator.pendingLaunchesBuilder = { PendingLaunchesView(model).eraseToAnyView() }
        }
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator).environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: size.width, height: size.height))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let vm, let scenario {
            await waitUntil(timeout: 10) {
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                return vm.presentation.kind == .inventory
            }
            if scenario != .inventory { vm.didSelectRow(Self.launchID) }
            await waitUntil(timeout: 10) {
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                return vm.detail?.kind == (scenario == .checking ? .checking : .waiting) || (scenario == .inventory && vm.detail == nil)
            }
        }
        await pump(window, passes: 60)
        return Shell(window: window, coordinator: coordinator, vm: vm, useCase: useCase, adapter: adapter)
    }

    // MARK: Accessibility tree of the principal

    private func subtree(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        while let next = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: kids) }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func matches(_ object: NSObject, _ text: String) -> Bool {
        ["accessibilityLabel", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            return object.responds(to: selector) && (object.perform(selector)?.takeUnretainedValue() as? String) == text
        }
    }

    /// The toolbar item that draws `text`.
    private func item(_ window: NSWindow, containing text: String) -> NSToolbarItem? {
        window.toolbar?.items.first { item in item.view.map { subtree($0).contains { matches($0, text) } } ?? false }
    }

    /// The screen frames of the elements of the item labelled `text`, left to right.
    private func frames(of text: String, in item: NSToolbarItem) -> [CGRect] {
        let objects = item.view.map { subtree($0).filter { matches($0, text) } } ?? []
        let frames: [CGRect] = objects.compactMap { object in
            if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
            guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
                  let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
            return value.rectValue
        }
        return frames.filter { $0 != .zero }.sorted { $0.minX < $1.minX }
    }

    /// The first (leftmost) frame labelled `text`.
    private func frame(of text: String, in item: NSToolbarItem) -> CGRect? { frames(of: text, in: item).first }

    /// Whether the body shows `scenario`'s screen: the VM's own screen state, and for a detail the card's text in the
    /// window's accessibility tree (the inventory's rows are not exposed to it).
    private func bodyShows(_ scenario: Scenario, _ mounted: Shell) -> Bool {
        guard let vm = mounted.vm else { return false }
        switch scenario {
        case .inventory: return vm.detail == nil && vm.presentation.kind == .inventory && !bodyHas("Waiting for resources", in: mounted.window)
        case .qualifiedDetail: return vm.detail?.kind == .waiting && bodyHas(scenario.bodyLine, in: mounted.window)
        case .checking: return vm.detail?.kind == .checking && bodyHas(scenario.bodyLine, in: mounted.window)
        }
    }

    /// Whether any element of the window's tree has a label, value or title containing `text`.
    private func bodyHas(_ text: String, in window: NSWindow) -> Bool {
        ShellMatrix.tree(window).contains { object in
            [ShellMatrix.label(object), ShellMatrix.value(object), ShellMatrix.string(object, "accessibilityTitle")].contains { $0?.contains(text) == true }
        }
    }

    // MARK: Assertions

    @Test(arguments: Scenario.allCases)
    func givenAPendingLaunchesScreen_whenMountedInTheShell_thenThePrincipalDrawsTheVMsTitleAndTheBadgeForTheBodyShown(scenario: Scenario) async throws {
        // given / when
        let mounted = await shell(scenario, size: CGSize(width: 1280, height: 800))
        defer { mounted.close() }

        // then — the body is the screen the title was published for
        #expect(bodyShows(scenario, mounted), "body for \(scenario)")
        #expect(mounted.coordinator.topBar.shownPage?.title == scenario.title)
        // then — one principal item holds the title and, after it, the badge, on one line
        let principal = try #require(item(mounted.window, containing: scenario.title), "no title in \(scenario)")
        #expect(item(mounted.window, containing: "Pending launch") === principal, "the badge shares the principal item")
        // A neutral detail's title and its badge both read "Pending launch": the leftmost is the title, the rightmost the badge.
        let title = try #require(frames(of: scenario.title, in: principal).first)
        let badge = try #require(frames(of: "Pending launch", in: principal).last)
        #expect(title != badge, "title and badge are separate elements")
        #expect(title.maxX <= badge.minX + 0.5, "title \(title) then badge \(badge)")
        #expect(abs(title.midY - badge.midY) <= 4, "one line: \(title) \(badge)")
        #expect(abs(badge.height - 22) <= 1, "the badge is 22 pt high: \(badge)")
    }

    @Test func givenNoWriterYet_whenTheShellDrawsTheFirstFrame_thenThePrincipalDrawsThePageShape() async throws {
        // given / when
        let mounted = await shell(nil, size: CGSize(width: 1280, height: 800))
        defer { mounted.close() }

        // then
        #expect(mounted.coordinator.topBar.shownPage == nil)
        let principal = try #require(item(mounted.window, containing: "Pending launches"))
        #expect(frame(of: "Pending launch", in: principal) != nil)
    }

    @Test func givenTheInventory_whenARowIsSelectedAndBackIsTapped_thenTheTitleFollowsTheScreen() async throws {
        // given
        let mounted = await shell(.inventory, size: CGSize(width: 1280, height: 800))
        defer { mounted.close() }
        let vm = try #require(mounted.vm)
        #expect(mounted.coordinator.topBar.shownPage?.title == "Pending launches")

        // when
        vm.didSelectRow(Self.launchID)
        await waitUntil(timeout: 10) { mounted.coordinator.topBar.shownPage?.title == "Review launch admission checks" && vm.detail?.kind == .waiting }

        // then
        #expect(mounted.coordinator.topBar.shownPage?.title == "Review launch admission checks")
        #expect(vm.detail?.kind == .waiting)

        // when
        vm.didTapBack()
        await waitUntil(timeout: 10) { mounted.coordinator.topBar.shownPage?.title == "Pending launches" && vm.detail == nil }

        // then
        #expect(mounted.coordinator.topBar.shownPage?.title == "Pending launches")
        #expect(vm.detail == nil)
    }

    @Test func givenAnotherDestination_whenSelected_thenThePageContentIsNotShown() async throws {
        // given
        let mounted = await shell(.qualifiedDetail, size: CGSize(width: 1280, height: 800))
        defer { mounted.close() }
        #expect(mounted.coordinator.topBar.shownPage != nil)
        #expect(item(mounted.window, containing: "Pending launch") != nil)

        // when: the selection moves on; the page leaves the shell and its view model clears its writer.
        mounted.coordinator.selection = .statistics
        await pump(mounted.window, passes: 60)

        // then
        #expect(mounted.coordinator.topBar.shownPage == nil)
        #expect(item(mounted.window, containing: "Pending launch") == nil)
        #expect(item(mounted.window, containing: "Pending launches") == nil)
        #expect(item(mounted.window, containing: "Review launch admission checks") == nil)
    }

    // MARK: Captures

    @Test(arguments: Scenario.allCases, [false, true])
    func givenAScenario_whenTheCaptureDirectoryIsSet_thenThePrincipalAndBodyAreCapturedAtBothSizes(scenario: Scenario, dark: Bool) async throws {
        guard let directory = HostedCaptureEvidence.directory(Self.captureKey) else { return }
        for size in [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)] {
            // given
            let mounted = await shell(scenario, size: size, dark: dark)
            defer { mounted.close() }
            await HostedCaptureEvidence.prepare(mounted.window, dark: dark)

            // then
            #expect(bodyShows(scenario, mounted), "body for \(scenario) at \(size)")
            let principal = try #require(item(mounted.window, containing: scenario.title))
            #expect(frame(of: "Pending launch", in: principal) != nil)
            #expect(mounted.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua))
            let host = try #require(mounted.window.contentView)
            let subject = HostedCaptureEvidence.Subject(
                suite: "pending-topbar", state: scenario.rawValue, dark: dark, size: NSSize(width: size.width, height: size.height),
                design: .init(route: scenario.route, file: Self.designFile, commit: Self.designCommit))
            try await HostedCaptureEvidence.record(directory: directory, subject: subject, window: mounted.window, host: host)
        }
    }
}
