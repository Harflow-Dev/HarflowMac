import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarNativeAliasTransitionHostedTests {
    @Test
    func givenRealAliasCells_whenRelayFadesAndReverses_thenEveryOccurrenceKeepsIdentityAcrossPolicies() async throws {
        for dark in [false, true] {
            for reduceMotion in [false, true] {
                let fixture = try await NativeSidebarWindowFixture(
                    dark: dark, reduceMotion: reduceMotion, aliasFixture: true
                )
                defer { fixture.close() }
                fixture.model.didToggleExpansion(taskID: "group:g")
                await fixture.model.waitForPresentation()
                await fixture.settle()
                let coordinator = try #require(fixture.outline.delegate as? SidebarNativeList.Coordinator)
                let displaySet = try #require(coordinator.logicalDisplays["task:g1"])
                let displays = Array(displaySet)
                let nativeIDs = try nativeIDs(for: displays, coordinator: coordinator)
                let baseline = baseline(for: displays, coordinator: coordinator, outline: fixture.outline)
                #expect(baseline.count == displays.count)
                #expect(baseline.values.allSatisfy { $0.row > 0 })

                // Hold the detached reconciliation job while the relay publishes the visible
                // fade. This keeps an equivalent poll from erasing the transition before the
                // native cells have reported their occupied geometry.
                let gate = AliasTransitionGate()
                coordinator.reconciliationBarrier = { await gate.wait() }
                let appliedInput = try #require(coordinator.appliedInput)
                coordinator.update(presentation: appliedInput, selection: coordinator.selection,
                                    seenIDs: coordinator.seenIDs, environment: coordinator.environment)
                await gate.waitUntilEntered()

                await verifyTransitions(context: AliasTransitionContext(
                    displays: displays, baseline: baseline, nativeIDs: nativeIDs, coordinator: coordinator,
                    outline: fixture.outline, reduceMotion: reduceMotion, layout: fixture.layout
                ))
                await gate.release()
            }
        }
    }
}

@MainActor
private func nativeIDs(
    for displays: [SidebarDisplayID], coordinator: SidebarNativeList.Coordinator
) throws -> [SidebarDisplayID: SidebarNativeIdentity] {
    try Dictionary(uniqueKeysWithValues: displays.map { display in
        (display, try #require(coordinator.boxesByID[display]?.entry.nativeID))
    })
}

@MainActor
private func baseline(
    for displays: [SidebarDisplayID], coordinator: SidebarNativeList.Coordinator, outline: NSOutlineView
) -> [SidebarDisplayID: AliasGeometry] {
    Dictionary(uniqueKeysWithValues: displays.compactMap { display in
        guard let row = coordinator.indexesByID[display], let cell = coordinator.cells[display] else { return nil }
        return (display, AliasGeometry(row: outline.rect(ofRow: row).height, frame: cell.frame.height,
                                       host: cell.host?.frame.height, report: coordinator.boxesByID[display]?.latestHostedReport))
    })
}

@MainActor
private func verifyTransitions(
    context: AliasTransitionContext
) async {
    let displays = context.displays
    let baseline = context.baseline
    let nativeIDs = context.nativeIDs
    let coordinator = context.coordinator
    let outline = context.outline
    let reduceMotion = context.reduceMotion
    let layout = context.layout
    coordinator.transition(ids: ["task:g1", "task:g2"], restored: [], epoch: 11, ended: false)
    await waitUntil(timeout: 5) {
        layout()
        return displays.allSatisfy { display in
            guard let box = coordinator.boxesByID[display], let cell = coordinator.cells[display],
                  let row = coordinator.indexesByID[display] else { return false }
            let current = outline.rect(ofRow: row).height
            let original = baseline[display]?.row ?? .greatestFiniteMagnitude
            let geometryMatches = reduceMotion ? abs(current - original) <= 1
                : current <= min(original - 1, PbRadius.Metrics.hairlineStroke + 1)
            return box.entry.isFading && cell.host?.rootView.entry.isFading == true && geometryMatches
        }
    }
    #expect(displays.allSatisfy { coordinator.boxesByID[$0]?.entry.isFading == true })
    #expect(displays.allSatisfy { display in
        guard let cell = coordinator.cells[display], let row = coordinator.indexesByID[display] else { return false }
        let current = outline.rect(ofRow: row).height
        let original = baseline[display]?.row ?? .greatestFiniteMagnitude
        let geometryMatches = reduceMotion ? abs(current - original) <= 1
            : current <= min(original - 1, PbRadius.Metrics.hairlineStroke + 1)
        return cell.host?.rootView.entry.isFading == true && geometryMatches
    })
    #expect(displays.allSatisfy { coordinator.boxesByID[$0]?.entry.nativeID == nativeIDs[$0] })

    coordinator.transition(ids: [], restored: ["task:g1", "task:g2"], epoch: 12, ended: false)
    await waitUntil(timeout: 5) {
        layout()
        return displays.allSatisfy { display in
            guard let box = coordinator.boxesByID[display], let cell = coordinator.cells[display],
                  let row = coordinator.indexesByID[display], let original = baseline[display] else { return false }
            return box.entry.isFading == false && cell.host?.rootView.entry.isFading == false
                && geometry(of: row, cell: cell, report: box.latestHostedReport, outline: outline).matches(original)
        }
    }
    #expect(displays.allSatisfy { coordinator.boxesByID[$0]?.entry.isFading == false })
    #expect(displays.allSatisfy { display in
        guard let box = coordinator.boxesByID[display], let cell = coordinator.cells[display],
              let row = coordinator.indexesByID[display], let original = baseline[display] else { return false }
        return cell.host?.rootView.entry.isFading == false
            && geometry(of: row, cell: cell, report: box.latestHostedReport, outline: outline).matches(original)
    })
    #expect(displays.allSatisfy { coordinator.boxesByID[$0]?.entry.nativeID == nativeIDs[$0] })
}

@MainActor
private struct AliasTransitionContext {
    let displays: [SidebarDisplayID]
    let baseline: [SidebarDisplayID: AliasGeometry]
    let nativeIDs: [SidebarDisplayID: SidebarNativeIdentity]
    let coordinator: SidebarNativeList.Coordinator
    let outline: NSOutlineView
    let reduceMotion: Bool
    let layout: () -> Void
}

@MainActor
private func geometry(
    of row: Int, cell: SidebarNativeCell, report: CGFloat?, outline: NSOutlineView
) -> AliasGeometry {
    AliasGeometry(row: outline.rect(ofRow: row).height, frame: cell.frame.height,
                  host: cell.host?.frame.height, report: report)
}

private struct AliasGeometry {
    let row: CGFloat
    let frame: CGFloat
    let host: CGFloat?
    let report: CGFloat?

    func matches(_ other: Self) -> Bool {
        abs(row - other.row) <= 1 && abs(frame - other.frame) <= 1
            && optionalMatches(host, other.host) && optionalMatches(report, other.report)
    }

    private func optionalMatches(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): abs(lhs - rhs) <= 1
        case (.none, .none): true
        default: false
        }
    }
}

private actor AliasTransitionGate {
    private var entered = false
    private var released = false

    func wait() async {
        entered = true
        while !released { await Task.yield() }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
    }
}
