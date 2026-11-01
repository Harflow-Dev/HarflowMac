import SwiftUI

// MARK: - ResourceSlotsReadingState diagnostics

/// The opt-in synthetic diagnostic channel: bounded, side-effect free observation of
/// every restoration transition. Only the diagnostic plumbing lives here; the reading
/// state's own restoration and focus lifecycle stays in the main file.
extension ResourceSlotsReadingState {
    func recordGroupUpdate(groupID: String, frames: ResourceSlotsDiagnosticFrames, accepted: Bool) {
        recordDiagnostic(event: accepted ? "group-update-accepted" : "group-update-rejected", callbackTarget: .group(groupID),
                         viewport: frames.viewport, content: frames.content,
                         rejection: frameRejection(target: .group(groupID), viewport: frames.viewport, content: frames.content))
    }

    func groupPendingReason(groupID: String, geometry: ResourceSlotsScrollGeometry) -> String {
        ResourceSlotsDiagnosticFrames.pendingReason(frames: groups[groupID], geometry: geometry,
                                                   coordinateSpaceDelta: Self.coordinateSpaceDelta, pending: idScrollRequest != nil)
    }

    func recordCommandExtent() {
        diagnosticCommandExtent = latestGeometry?.contentHeight
        diagnosticReportedExtent = diagnosticCommandExtent
    }

    func recordContentExtent(_ geometry: ResourceSlotsScrollGeometry) {
        guard diagnosticCommandExtent != nil, diagnosticReportedExtent != geometry.contentHeight else { return }
        diagnosticReportedExtent = geometry.contentHeight
        recordDiagnostic(event: "content-extent-after-command", callbackGeometry: geometry)
    }

    func recordTargetGeometry(target: ResourceSlotsScrollTarget, viewport: CGRect, content: CGRect?) {
        guard diagnosticObserver != nil, isDiagnosticTarget(target) else { return }
        let rejection = frameRejection(target: target, viewport: viewport, content: content)
        recordDiagnostic(event: "target-geometry-callback", category: .geometry, callbackTarget: target,
                         viewport: viewport, content: content, rejection: rejection)
    }

    private func frameRejection(target: ResourceSlotsScrollTarget, viewport: CGRect, content: CGRect?) -> String? {
        let exists = switch target {
        case .owner(let id): rowGroups[id] != nil
        case .group(let id): availableGroups.contains(id)
        }
        return ResourceSlotsFrameDiagnosticContext(mounted: mounted, selected: selected, ready: ready, targetExists: exists,
                                                  viewportHeight: viewportHeight, geometry: latestGeometry,
                                                  coordinateSpaceDelta: Self.coordinateSpaceDelta)
            .rejection(frames: .init(viewport: viewport, content: content))
    }

    func isDiagnosticTarget(_ target: ResourceSlotsScrollTarget) -> Bool {
        switch target {
        case .group(let id): retainedAnchor?.groupID == id
        case .owner(let id): retainedAnchor?.rowID == id || focusedRowID == id
        }
    }

    func recordDiagnostic(event: String, category: ResourceSlotsDiagnosticRecord.Category = .transition,
                          callbackTarget: ResourceSlotsScrollTarget? = nil, viewport: CGRect? = nil,
                          content: CGRect? = nil, callbackGeometry: ResourceSlotsScrollGeometry? = nil, rejection: String? = nil,
                          finishReason: ResourceSlotsDiagnosticRecord.FinishReason? = nil, previousAnchor: Anchor? = nil) {
        guard let diagnosticObserver else { return }
        diagnosticSequence &+= 1
        let owner = (retainedAnchor?.rowID ?? focusedRowID).flatMap { owners[$0] }
        let group = retainedAnchor.flatMap { groups[$0.groupID] }
        let mountGroup = diagnosticMountTarget.flatMap { groups[$0.groupID] }
        let callbackGroupID: String? = if case .some(.group(let id)) = callbackTarget { id } else { nil }
        diagnosticObserver(.init(
            sequence: diagnosticSequence, event: event, category: category, phase: String(describing: phase),
            generation: generation, idScrollRequest: idScrollRequest, idRequestCount: groupDiscovery.totalAttempts,
            targetIDAttemptCount: requestedTarget.flatMap { groupDiscovery.attempts[$0] } ?? 0,
            discoverySettledFrames: groupDiscovery.settledFrames, idRequestTrigger: groupDiscovery.lastIssue?.trigger,
            idRequestBaseline: groupDiscovery.lastIssue?.baseline, idRequestContentHeight: groupDiscovery.lastIssue?.contentHeight,
            restorationFrames: restorationFrames, focusFrames: focusFrames, pointRequestCount: pointRequestCount,
            maximumPointRequests: Self.maximumPointRequests, outcome: restorationOutcome,
            maximumRestorationFrames: Self.maximumRestorationFrames,
            selected: selected, mounted: mounted, ready: ready, isRestoring: isRestoring,
            retainedOffset: retainedOffset, measuredOffset: measuredOffset, anchor: retainedAnchor,
            previousAnchor: previousAnchor, mountRestorationTarget: diagnosticMountTarget, mountRestorationOffset: diagnosticMountOffset,
            mountTargetGroupFrame: mountGroup.map { diagnosticFrame($0) }, callbackGroupID: callbackGroupID,
            cachedGroupCount: groups.count, commandContentHeight: diagnosticCommandExtent,
            requestedTarget: requestedTarget, requestedOffset: requestedOffset, geometry: latestGeometry, callbackGeometry: callbackGeometry,
            ownerFrame: owner.map { diagnosticFrame($0.frames) }, groupFrame: group.map { diagnosticFrame($0) },
            callbackTarget: callbackTarget, callbackViewportFrame: viewport, callbackContentFrame: content,
            viewportCoordinateSpace: "resourceSlotsViewport", contentCoordinateSpace: "resourceSlotsDiagnosticContent",
            coordinateSpaceDelta: Self.coordinateSpaceDelta,
            rejection: rejection, focusedRowID: focusedRowID, confirmedFocusID: diagnosticConfirmedFocusID,
            focusReturnAuthorized: focusReturnAuthorized, focusRestorationPending: focusRestorationPending,
            finishReason: finishReason
        ))
    }

    private func diagnosticFrame(_ frames: ResourceSlotsDiagnosticFrames) -> ResourceSlotsDiagnosticRecord.TargetFrame {
        .init(viewport: frames.viewport, measurementOffset: (frames.content?.minY ?? 0) - frames.viewport.minY, content: frames.content)
    }
}
