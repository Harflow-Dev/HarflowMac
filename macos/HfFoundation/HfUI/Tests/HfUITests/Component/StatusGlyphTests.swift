import AppKit
import HfTestUtilities
@testable import HfUI
import MonitorCore
import SwiftUI
import Testing

// MARK: - StatusGlyphTests

/// The approved task status glyph set (HarflowDesign `fe6428c`): which glyph, tint and spoken label each status and row
/// kind gets, the path glyphs' geometry, the parallel tint's contrast and the group row's single running announcement.
@MainActor @Suite(.serialized) struct StatusGlyphTests {

    private static let attention: [TaskStatus] = [.other("needs_input"), .other("Needs Input"), .other("needs attention"), .other("NEEDS_ATTENTION")]

    // MARK: Glyph table

    @Test func givenEachStatusOnATaskRow_whenChoosingTheGlyph_thenItIsTheApprovedOne() {
        // given / when / then
        #expect(StatusIcon.glyph(for: .completed) == .symbol("checkmark"))
        #expect(StatusIcon.glyph(for: .failed) == .symbol("xmark"))
        #expect(StatusIcon.glyph(for: .timedOut) == .symbol("xmark"))
        #expect(StatusIcon.glyph(for: .cancelled) == .symbol("stop.fill"))
        #expect(StatusIcon.glyph(for: .running) == .spinner)
        #expect(StatusIcon.glyph(for: .other("settling")) == .spinner)
        #expect(StatusIcon.glyph(for: .other("pending")) == .symbol("circle"))
        #expect(StatusIcon.glyph(for: .other("Queued")) == .symbol("circle"))
        #expect(StatusIcon.glyph(for: .other("paused")) == .symbol("circle.dashed"))
        for status in Self.attention { #expect(StatusIcon.glyph(for: status) == .shape(.hand), "\(status)") }
    }

    @Test func givenWorkflowRunAndParallelGroupKinds_whenChoosingTheGlyph_thenOnlyTheirApprovedStatesDifferFromATask() {
        // given / when / then
        #expect(StatusIcon.glyph(for: .completed, kind: .workflowRun) == .shape(.workflow))
        #expect(StatusIcon.glyph(for: .running, kind: .workflowRun) == .spinner)
        #expect(StatusIcon.glyph(for: .failed, kind: .workflowRun) == .symbol("xmark"))
        #expect(StatusIcon.glyph(for: .running, kind: .parallelGroup) == .shape(.parallel))
        #expect(StatusIcon.glyph(for: .other("needs_input"), kind: .workflowRun) == .shape(.hand))
    }

    @Test(arguments: [TaskStatus.completed, .failed, .cancelled, .timedOut])
    func givenATerminalParallelGroup_whenDrawn_thenItIsTheDoneParallelGlyph(status: TaskStatus) {
        // given / when / then
        #expect(StatusIcon.glyph(for: status, kind: .parallelGroup) == .shape(.parallel))
        #expect(StatusIcon.tint(for: status, kind: .parallelGroup) == .doneGreen)
        #expect(StatusIcon.accessibilityLabel(for: status, kind: .parallelGroup) == "Parallel group, done")
    }

    @Test func givenEveryStatusAndKind_whenReadingTheSymbolName_thenItIsDerivedFromTheTaskGlyph() {
        // given
        let statuses: [TaskStatus] = [.running, .completed, .failed, .timedOut, .cancelled, .other("pending"),
                                      .other("needs_input"), .other("settling"), .other("mystery")]

        // when / then
        for status in statuses {
            if case let .symbol(name) = StatusIcon.glyph(for: status, kind: .task) {
                #expect(StatusIcon.symbolName(for: status) == name)
            } else {
                #expect(StatusIcon.symbolName(for: status) == nil)
            }
        }
    }

    // MARK: Tints

    @Test func givenEachStatus_whenChoosingTheTint_thenItIsTheApprovedColour() {
        // given / when / then
        #expect(StatusIcon.tint(for: .completed) == .doneGreen)
        #expect(StatusIcon.tint(for: .completed, kind: .workflowRun) == .doneGreen)
        #expect(StatusIcon.tint(for: .failed) == .failedRed)
        #expect(StatusIcon.tint(for: .timedOut) == .failedRed)
        #expect(StatusIcon.tint(for: .cancelled) == .cancelledGray)
        #expect(StatusIcon.tint(for: .running, kind: .parallelGroup) == .runningFG)
        #expect(StatusIcon.tint(for: .other("pending")) == .cancelledGray)
        for status in Self.attention { #expect(StatusIcon.tint(for: status) == .warningFG, "\(status)") }
    }

    @Test func givenTheParallelGroupTint_whenOnTheDarkSidebar_thenItClearsTheGraphicalContrastFloor() {
        // given — the design uses its accent, whose dark value is `runningFG`; `accentFill` would miss 3:1 here.
        let sidebar = Palette.sidebarBG
        let accessible = [(Palette.runningFG.light, sidebar.light), (Palette.runningFG.dark, sidebar.dark)]

        // when / then
        for (foreground, background) in accessible { #expect(Contrast.ratio(foreground, background) >= 3) }
        #expect(Contrast.ratio(Palette.accentFill.dark, sidebar.dark) < 3, "accentFill is not a valid parallel tint on the dark sidebar")
    }

    // MARK: Labels

    @Test func givenEachStatusAndKind_whenReadingTheLabel_thenItFollowsTheDesign() {
        // given / when / then
        for status in Self.attention { #expect(StatusIcon.accessibilityLabel(for: status) == "Needs you", "\(status)") }
        #expect(StatusIcon.accessibilityLabel(for: .running, kind: .parallelGroup) == "Parallel group, running")
        #expect(StatusIcon.accessibilityLabel(for: .completed, kind: .workflowRun) == "Done")
        #expect(StatusIcon.accessibilityLabel(for: .running) == "Running")
        #expect(StatusIcon.accessibilityLabel(for: .timedOut) == "Timed out")
        #expect(StatusIcon.accessibilityLabel(for: .failed) == "Failed")
        #expect(StatusIcon.accessibilityLabel(for: .cancelled) == "Cancelled")
        #expect(StatusIcon.accessibilityLabel(for: .other("settling")) != "Running")
        #expect(StatusIcon.accessibilityLabel(for: .other("paused")) == TaskStatus.other("paused").label)
    }

    // MARK: Shapes

    @Test(arguments: StatusGlyphShape.Kind.allCases)
    func givenAGlyphShape_whenBuiltInTheViewBox_thenItIsNonEmptyAndInsideTheBox(kind: StatusGlyphShape.Kind) {
        // given
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)

        // when
        let bounds = StatusGlyphShape(kind).path(in: box).cgPath.boundingBoxOfPath

        // then
        #expect(!bounds.isEmpty)
        #expect(box.insetBy(dx: -0.01, dy: -0.01).contains(bounds))
    }

    @Test func givenTheDesignPathData_whenBuilt_thenTheTightBoundsMatchTheSvgGeometry() {
        // given
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        func bounds(_ kind: StatusGlyphShape.Kind) -> CGRect { StatusGlyphShape(kind).path(in: box).cgPath.boundingBoxOfPath }

        // when / then — parallel: x 3...20, y 6...18; workflow: x 3...21, y 3...21 (two 7 squares and the connector).
        let parallel = bounds(.parallel)
        #expect(abs(parallel.minX - 3) < 0.01 && abs(parallel.maxX - 20) < 0.01 && abs(parallel.minY - 6) < 0.01 && abs(parallel.maxY - 18) < 0.01)
        let workflow = bounds(.workflow)
        #expect(abs(workflow.minX - 3) < 0.01 && abs(workflow.maxX - 21) < 0.01 && abs(workflow.minY - 3) < 0.01 && abs(workflow.maxY - 21) < 0.01)
        // hand: middle finger top at y 2 (centre 4, radius 2), thumb edge at x 22, palm bottom at y 22.
        let hand = bounds(.hand)
        #expect(abs(hand.minY - 2) < 0.01 && abs(hand.maxX - 22) < 0.01 && abs(hand.maxY - 22) < 0.01)
        #expect(hand.minX > 0.5 && hand.minX < 3)
    }

    @Test(arguments: StatusGlyphShape.Kind.allCases)
    func givenARectOfAnySize_whenBuilt_thenTheGlyphScalesAndCentresInIt(kind: StatusGlyphShape.Kind) {
        // given
        let small = CGRect(x: 0, y: 0, width: 24, height: 24)
        let large = CGRect(x: 10, y: 20, width: 96, height: 96)

        // when
        let first = StatusGlyphShape(kind).path(in: small).cgPath.boundingBoxOfPath
        let second = StatusGlyphShape(kind).path(in: large).cgPath.boundingBoxOfPath

        // then
        #expect(abs(second.width - first.width * 4) < 0.05)
        #expect(abs((second.minX - 10) - first.minX * 4) < 0.05)
        #expect(abs((second.minY - 20) - first.minY * 4) < 0.05)
    }

    // MARK: Model

    @Test func givenTwoRowsDifferingOnlyInKind_whenComparing_thenTheyAreNotEqual() {
        // given
        func model(_ kind: StatusIcon.Kind) -> TaskRowModel {
            TaskRowModel(id: "a", backend: "workflow", title: "t", status: .completed, repoName: "r", ageText: "1m", kind: kind)
        }

        // when / then
        #expect(model(.workflowRun) != model(.task))
        #expect(model(.workflowRun) == model(.workflowRun))
        #expect(TaskRowModel(id: "a", backend: "claude", title: "t", status: .completed, repoName: "r", ageText: "1m").kind == .task)
    }

    // MARK: Group row

    private func group(_ statuses: [String]) -> ParallelGroup {
        let tasks = statuses.enumerated().map { index, status in
            TaskInfo(.object(["task_id": .string("m\(index)"), "backend": .string("claude"), "status": .string(status), "group": .string("g")]))!
        }
        return Lineage.sections(tasks).parallel.first!
    }

    private func labels(of row: some View, ready: String = "g") async -> [String] {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: row.environment(\.hfReduceMotionOverride, true).fixedSize())
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func collect(_ element: NSObject, _ seen: inout Set<ObjectIdentifier>) -> [String] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            var found: [String] = []
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] where element.responds(to: NSSelectorFromString(key)) {
                if let value = element.value(forKey: key) as? String { found.append(value) }
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [NSObject] {
                for child in children { found += collect(child, &seen) }
            }
            if let view = element as? NSView { for sub in view.subviews { found += collect(sub, &seen) } }
            return found
        }
        var result: [String] = []
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            var seen = Set<ObjectIdentifier>()
            result = collect(host, &seen)
            return result.contains { $0.contains(ready) }
        }
        return result
    }

    @Test(arguments: [false, true])
    func givenARunningParallelGroup_whenRendered_thenRunningIsAnnouncedOnceAsTheParallelGlyph(sidebar: Bool) async {
        // given
        let row = GroupRow(group: group(["running", "completed"]), sidebarAppearance: sidebar ? SidebarRowAppearance() : nil)

        // when
        let strings = await labels(of: row)

        // then
        #expect(strings.filter { $0.localizedCaseInsensitiveContains("running") && $0 != "Parallel run · 1 of 2 finished" }.count == 1)
        #expect(strings.filter { $0 == "Parallel group, running" }.count == 1)
        #expect(!strings.contains("Running"))
    }

    @Test func givenARunningSingleMemberGroup_whenRendered_thenTheRowAnnouncesRunningOnlyThroughItsSubtitle() async {
        // given
        let row = GroupRow(group: group(["running"]), sidebarAppearance: SidebarRowAppearance())

        // when
        let strings = await labels(of: row)

        // then — the subtitle is the one announcement; the spinner's own "Running" is hidden.
        #expect(strings.contains("Group · Running"))
        #expect(strings.filter { $0.localizedCaseInsensitiveContains("running") }.count == 1, "\(strings)")
        #expect(!strings.contains("Parallel group, running"))
    }

    @Test(arguments: [false, true])
    func givenAFinishedMultiMemberGroup_whenRendered_thenTheParallelGlyphIsAnnouncedDoneOnce(sidebar: Bool) async {
        // given
        let row = GroupRow(group: group(["completed", "failed"]), sidebarAppearance: sidebar ? SidebarRowAppearance() : nil)

        // when
        let strings = await labels(of: row)

        // then — positive first, so an empty accessibility tree cannot pass.
        #expect(strings.contains("Parallel run · 2 of 2 finished"), "\(strings)")
        #expect(strings.contains("g"))
        #expect(strings.filter { $0 == "Parallel group, done" }.count == 1, "\(strings)")
        #expect(!strings.contains("Running") && !strings.contains("Parallel group, running"))
    }

    @Test func givenAFinishedSingleMemberGroup_whenRendered_thenItKeepsBackendDotsAndNoGroupGlyph() async {
        // given
        let row = GroupRow(group: group(["completed"]), sidebarAppearance: SidebarRowAppearance())

        // when
        let strings = await labels(of: row)

        // then
        #expect(strings.contains("Group · Done"), "\(strings)")
        #expect(strings.contains("Claude"), "\(strings)")
        #expect(!strings.contains("Parallel group, done") && !strings.contains("Parallel group, running"))
    }

    @Test(arguments: [false, true])
    func givenAWaitingMultiMemberGroup_whenRendered_thenItIsNotAnnouncedDone(sidebar: Bool) async {
        // given
        let row = GroupRow(group: group(["needs_input", "completed"]), sidebarAppearance: sidebar ? SidebarRowAppearance() : nil)

        // when
        let strings = await labels(of: row)

        // then — positive first, so an empty accessibility tree cannot pass.
        #expect(strings.contains("Parallel run · 1 of 2 finished"), "\(strings)")
        #expect(!strings.contains("Parallel group, done"), "\(strings)")
    }

    // MARK: Task row

    private func taskRow(_ status: TaskStatus, kind: StatusIcon.Kind = .task, sidebar: Bool) -> some View {
        TaskRow(model: TaskRowModel(id: "t", backend: "claude", title: "Row title", status: status, repoName: "repo",
                                    ageText: "2m", kind: kind),
                sidebarAppearance: sidebar ? SidebarRowAppearance() : nil)
    }

    @Test(arguments: [false, true])
    func givenNeedsInputTaskRow_whenHosted_thenTheRowAnnouncesNeedsYou(sidebar: Bool) async {
        // given / when
        let strings = await labels(of: taskRow(.other("needs_input"), sidebar: sidebar), ready: "Row title")

        // then
        #expect(strings.contains { $0.contains("Row title") })
        #expect(strings.contains { $0.contains("Needs you") }, "\(strings)")
    }

    @Test(arguments: [false, true])
    func givenCompletedWorkflowRunRow_whenHosted_thenTheRowAnnouncesDone(sidebar: Bool) async {
        // given / when
        let strings = await labels(of: taskRow(.completed, kind: .workflowRun, sidebar: sidebar), ready: "Row title")

        // then
        #expect(strings.contains { $0.contains("Row title") })
        #expect(strings.contains { $0.contains("Done") }, "\(strings)")
    }
}
