import AppKit
import MonitorCore
import PbTestUtilities
@testable import PbUI
import SwiftUI
import Testing

// MARK: - TaskRowSidebarRenderingTests

/// The sidebar's presentation-only row input (Phase 1, SPEC §§3, 6.1): the shared default's
/// geometry characterized beside the sidebar's diverging one (Menu Bar keeps the default
/// byte-identical), the alias `selectedRow` fill's contrast floor, and the honest terminal
/// "finished" count. Contrast is measured with the same WCAG helpers the palette tests use.
@MainActor
@Suite(.serialized) struct TaskRowSidebarRenderingTests {

    // MARK: - Fixtures

    private func model(status: TaskStatus = .completed, guides: [TreeGuide] = []) -> TaskRowModel {
        TaskRowModel(
            id: "t1", backend: "claude", title: "Fix the login bug", status: status, repoName: "repo",
            ageText: "3h", guides: guides
        )
    }

    /// The intrinsic fitted size of a hosted view — `fixedSize` on both axes so a row hugs its
    /// content instead of expanding, then `NSHostingView.fittingSize`.
    private func fittedSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.fixedSize())
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - Sidebar metadata identity

    @Test(arguments: ["claude", "custom-backend", "workflow"], ["repo", ""])
    func givenExistingRowMetadata_whenSidebarSubtitleIsDerived_thenAgentComesFirstWithoutChangingSharedSubtitle(
        backend: String, repo: String
    ) {
        for summary in [nil, "2 sub-tasks, 1 running"] as [String?] {
            // given
            let row = TaskRowModel(id: "metadata", backend: backend, title: "Task", status: .completed,
                                   repoName: repo, ageText: "3h", subTaskSummary: summary)
            let agent = BackendStyle.displayName(backend)
            let suffix = summary.map { " · \($0)" } ?? ""

            // when
            let sidebar = row.sidebarSubtitle
            let shared = row.subtitle

            // then — the existing display-name mapping handles unknown and workflow identities.
            #expect(sidebar == agent + (repo.isEmpty ? "" : " · \(repo)") + suffix)
            #expect(shared == (repo.isEmpty ? "" : "\(repo) · ") + agent + suffix)
        }
    }

    @Test(arguments: [false, true])
    func givenActualTaskRow_whenHosted_thenItsMetadataUsesTheSelectedAppearance(sidebar: Bool) async throws {
        // given — activate only this test application's accessibility descriptors.
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let row = model()
        let host = NSHostingView(rootView: TaskRow(model: row, sidebarAppearance: sidebar ? SidebarRowAppearance() : nil).fixedSize())
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let expected = sidebar ? row.sidebarSubtitle : row.subtitle

        // when — inspect the actual Text emitted by the production view, not just the helper.
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return accessibilityStrings(in: host).contains(expected)
        }
        let strings = accessibilityStrings(in: host)

        // then
        #expect(strings.contains(expected))
        #expect(!strings.contains(sidebar ? row.subtitle : row.sidebarSubtitle))
    }

    private func accessibilityStrings(in host: NSView) -> Set<String> {
        var strings: Set<String> = []
        var visited: Set<ObjectIdentifier> = []
        func collect(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            for key in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] where element.responds(to: NSSelectorFromString(key)) {
                if let value = element.value(forKey: key) as? String { strings.insert(value) }
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [NSObject] {
                children.forEach(collect)
            }
            if let view = element as? NSView { view.subviews.forEach(collect) }
        }
        collect(host)
        return strings
    }

    // MARK: - Default versus sidebar geometry

    @Test func givenTheSidebarAppearance_whenMeasured_thenRowsFitTheLargerMetaAndPadding() {
        // given / when — the same single-line model rendered with the shared default and the
        // sidebar's appearance input.
        let defaultHeight = fittedSize(TaskRow(model: model())).height
        let sidebarHeight = fittedSize(TaskRow(model: model(), sidebarAppearance: SidebarRowAppearance())).height

        // then — sidebar metadata grows from caption to secondary, alongside the 7 pt padding.
        // Any default consumer keeps its original caption and 6 pt padding.
        #expect(sidebarHeight > defaultHeight + 2 * (PbRadius.Metrics.sidebarRowPaddingVertical - PbRadius.Metrics.rowPaddingVertical))
    }

    @Test func givenChildGuides_whenMeasured_thenTheSidebarIndentColumnIsTwentyPoints() {
        // given — a child row's guide column, rendered in both appearances.
        let plainDefault = fittedSize(TaskRow(model: model())).width
        let childDefault = fittedSize(TaskRow(model: model(guides: [.branch]))).width
        let plainSidebar = fittedSize(TaskRow(model: model(), sidebarAppearance: SidebarRowAppearance())).width
        let childSidebar = fittedSize(TaskRow(model: model(guides: [.branch]), sidebarAppearance: SidebarRowAppearance())).width

        // when / then — the default retains its 16 pt column plus the existing row gap.
        // Sidebar compensates that gap so the complete child indent is exactly 20 pt (§6.1).
        #expect(childDefault - plainDefault == PbRadius.Metrics.treeGutterColumnWidth + PbRadius.Metrics.rowItemSpacing)
        #expect(childSidebar - plainSidebar == PbRadius.Metrics.sidebarChildGuideWidth)
    }

    @Test func givenStatusIcon_whenGivenTheSidebarSize_thenItsFrameTracksTheInput() {
        // given / when
        let shared = fittedSize(StatusIcon(status: .completed))
        let sidebar = fittedSize(StatusIcon(status: .completed, size: PbRadius.Metrics.sidebarStatusIconSize))

        // then — the frame is the presentation-only size input; the default consumer keeps 16 pt
        // and the sidebar's glyph is the 15 pt metric (§6.1).
        #expect(shared.width == PbRadius.Metrics.statusIconSize)
        #expect(shared.height == PbRadius.Metrics.statusIconSize)
        #expect(sidebar.width == PbRadius.Metrics.sidebarStatusIconSize)
        #expect(sidebar.height == PbRadius.Metrics.sidebarStatusIconSize)
    }

    @Test func givenSidebarRowAppearance_whenCompared_thenOnlyTheSelectedFillDistinguishesIt() {
        // given / when / then — a pure view input: default and explicit-plain are equal, and only
        // the alias fill flag separates values.
        #expect(SidebarRowAppearance() == SidebarRowAppearance(isSelectedFill: false))
        #expect(SidebarRowAppearance() != SidebarRowAppearance(isSelectedFill: true))
    }

    // MARK: - Alias selectedRow contrast

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenSidebarRowText_whenDrawnOnTheAliasSelectedFill_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        // given — the texts the sidebar's rows draw on the duplicate-alias fill (`selectedRow`)
        // and on the fallback surface the preview canvases use.
        let texts: [(String, Color)] = [("primaryText", .primaryText), ("secondaryText", .secondaryText)]
        let surfaces: [(String, Color)] = [("selectedRow", .selectedRow), ("sidebarBG", .sidebarBG)]

        for (textName, text) in texts {
            for (surfaceName, surface) in surfaces {
                // when
                let ratio = Contrast.ratio(Resolved.hex(text, in: appearance), Resolved.hex(surface, in: appearance))

                // then — titles render primaryText and the alias fill's timestamps/meta
                // secondaryText precisely because both hold the 4.5:1 floor there.
                #expect(ratio >= 4.5, "\(textName) on \(surfaceName) in \(appearance.rawValue): \(ratio)")
            }
        }
    }

    @Test func givenDarkTertiaryText_whenDrawnOnTheAliasSelectedFill_thenItMissesReadableContrast() {
        // given — dark tertiary (the approved 0x909099) on the dark `selectedRow` fill.
        let tertiary = Resolved.hex(Color.tertiaryText, in: .darkAqua)
        let fill = Resolved.hex(Color.selectedRow, in: .darkAqua)

        // when
        let ratio = Contrast.ratio(tertiary, fill)

        // then — under the floor (4.35 measured): the reason the alias fill's timestamps render
        // secondaryText instead, pinned here so the substitution is never read as decoration.
        #expect(ratio < 4.5, "dark tertiary on selectedRow: \(ratio)")
    }

    // MARK: - Honest finished count

    @Test func givenTerminalMembers_whenCountedAsFinished_thenFailedAndCancelledCount() {
        // given — every terminal member a parallel group can hold.
        let statuses: [TaskStatus] = [.completed, .failed, .cancelled, .timedOut, .running, .other("queued")]

        // when
        let finished = GroupRow.finishedCount(of: statuses)

        // then — "finished" means settled, not succeeded (SPEC §1.6 keeps the honest word): the
        // done, failed, cancelled and timed-out members all count; running and pending do not.
        #expect(finished == 4)
    }
}
