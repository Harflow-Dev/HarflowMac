import AppKit
@testable import MainWindowFeature
import Observation
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SidebarNativeEnvironmentHostedTests {
    // swiftlint:disable:next function_body_length
    @Test func givenMountedNativeSidebar_whenInheritedEnvironmentChanges_thenRetainedCellReceivesEveryInput() async throws {
        // given — a real representable, retained window, and one stable task entry.
        _ = NSApplication.shared
        let state = HostedEnvironmentState()
        let host = NSHostingView(rootView: HostedEnvironmentView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return Self.descendants(host).compactMap { $0 as? NSOutlineView }.first?.numberOfRows ?? 0 > 0
        }
        let outline = try #require(Self.descendants(host).compactMap { $0 as? NSOutlineView }.first)
        let coordinator = try #require(outline.delegate as? SidebarNativeList.Coordinator)
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return coordinator.cells[SidebarDisplayID(logicalID: "task:stable")]?.host != nil && coordinator.fingerprint != nil
        }
        let cell = try #require(coordinator.cells[SidebarDisplayID(logicalID: "task:stable")])
        let cellID = ObjectIdentifier(cell)
        let hostedView = try #require(cell.host)
        let hostID = ObjectIdentifier(hostedView)
        let initial = try #require(coordinator.fingerprint)

        // when — change each inherited input independently through SwiftUI's environment.
        let mutations: [@MainActor () -> Void] = [
            { state.font = .system(size: 13) },
            { state.minimumHeight = 8 },
            { state.colorScheme = .dark },
            { state.legibility = .bold },
            { state.dynamicType = .accessibility2 },
            { state.locale = Locale(identifier: "id-ID") },
            { state.direction = .rightToLeft },
            { state.displayScale = 2 },
            { state.controlSize = .large },
            { state.enabled = false },
            { state.motionOverride = true },
            { state.shimmerOverride = false }
        ]
        for mutate in mutations {
            let before = coordinator.fingerprint
            mutate()
            await waitUntil {
                host.layoutSubtreeIfNeeded()
                return coordinator.fingerprint != before
            }
            let refreshedCell = try #require(coordinator.cells[SidebarDisplayID(logicalID: "task:stable")])
            #expect(ObjectIdentifier(refreshedCell) == cellID)
            #expect(refreshedCell.host.map(ObjectIdentifier.init) == hostID)
        }

        // then — the final retained cell sees the complete latest environment.
        let final = try #require(coordinator.fingerprint)
        #expect(final != initial)
        #expect(final.colorScheme == .dark)
        #expect(final.legibility == .bold)
        #expect(final.dynamicType == .accessibility2)
        #expect(final.locale.identifier == "id-ID")
        #expect(final.direction == .rightToLeft)
        #expect(final.displayScale == 2)
        #expect(final.controlSize == .large)
        #expect(!final.enabled)
        #expect(final.motionOverride == true)
        #expect(final.shimmerOverride == false)
        let finalCell = try #require(coordinator.cells[SidebarDisplayID(logicalID: "task:stable")])
        let renderedEnvironment = finalCell.host?.rootView.environment
        #expect(renderedEnvironment?.font != nil)
        #expect(renderedEnvironment?.defaultMinListRowHeight == 8)
        #expect(renderedEnvironment?.colorScheme == .dark)
        #expect(renderedEnvironment?.legibilityWeight == .bold)
        #expect(renderedEnvironment?.dynamicTypeSize == .accessibility2)
        #expect(renderedEnvironment?.locale.identifier == "id-ID")
        #expect(renderedEnvironment?.layoutDirection == .rightToLeft)
        #expect(renderedEnvironment?.displayScale == 2)
        #expect(renderedEnvironment?.controlSize == .large)
        #expect(renderedEnvironment?.isEnabled == false)
        #expect(renderedEnvironment?.accessibilityReduceMotion == EnvironmentValues().accessibilityReduceMotion)
        #expect(renderedEnvironment?.pbReduceMotionOverride == true)
        #expect(renderedEnvironment?.shimmerReduceMotionOverride == false)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor @Observable private final class HostedEnvironmentState {
    var presentation = SidebarListPresentation(
        sections: [SidebarSection(bucket: .today, items: [
            .task(TaskRowModel(id: "stable", backend: "codex", title: "Stable", status: .running,
                               repoName: "repo", ageText: "1m"))
        ])], workflowTitles: [], workflowsExpanded: true, banner: nil, listError: nil, skeleton: false,
        taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(), emptyMessage: nil,
        fadingIDs: [], minimumRowHeight: 0, historyRevision: 0, historyToken: "environment")
    var font: Font?
    var minimumHeight: CGFloat = 0
    var colorScheme: ColorScheme = .light
    var legibility: LegibilityWeight?
    var dynamicType: DynamicTypeSize = .medium
    var locale = Locale(identifier: "en-US")
    var direction: LayoutDirection = .leftToRight
    var displayScale: CGFloat = 1
    var controlSize: ControlSize = .regular
    var enabled = true
    var motionOverride: Bool?
    var shimmerOverride: Bool?
}

private struct HostedEnvironmentView: View {
    let state: HostedEnvironmentState

    var body: some View {
        SidebarNativeList(presentation: state.presentation, selection: nil, seenIDs: [], configureActions: { _ in })
            .environment(\.font, state.font)
            .environment(\.defaultMinListRowHeight, state.minimumHeight)
            .environment(\.colorScheme, state.colorScheme)
            .environment(\.legibilityWeight, state.legibility)
            .environment(\.dynamicTypeSize, state.dynamicType)
            .environment(\.locale, state.locale)
            .environment(\.layoutDirection, state.direction)
            .environment(\.displayScale, state.displayScale)
            .environment(\.controlSize, state.controlSize)
            .disabled(!state.enabled)
            .environment(\.pbReduceMotionOverride, state.motionOverride)
            .environment(\.shimmerReduceMotionOverride, state.shimmerOverride)
            .frame(width: 360, height: 260)
    }
}
