import AppKit
import Observation
import SwiftUI

// MARK: - ResourceSlotsReadingState

/// Retains verified reading intent independently of reconstructed lazy-layout measurements.
@Observable @MainActor
final class ResourceSlotsReadingState {
    static let maximumRestorationFrames = 64
    static let maximumPointRequests = 8
    static let coordinateSpaceDelta: CGFloat = 0
    @ObservationIgnored var diagnosticObserver: (@MainActor (ResourceSlotsDiagnosticRecord) -> Void)?
    var position = ScrollPosition()
    var focusedRowID: String?
    private(set) var isRestoring = false
    private(set) var focusRestorationPending = false
    private(set) var focusReturnRequest: ResourceSlotsFocusReturnRequest?
    private(set) var idScrollRequest: ResourceSlotsIDScrollRequest?
    private(set) var restorationOutcome: ResourceSlotsRestorationOutcome?
    @ObservationIgnored private(set) var viewportHeight: CGFloat = 0
    @ObservationIgnored private(set) var retainedOffset: CGFloat = 0
    @ObservationIgnored private(set) var measuredOffset: CGFloat = 0
    @ObservationIgnored private(set) var retainedAnchor: Anchor? {
        didSet {
            if diagnosticObserver != nil, oldValue != retainedAnchor {
                recordDiagnostic(event: "anchor-reassigned", previousAnchor: oldValue)
            }
        }
    }

    @ObservationIgnored private(set) var restorationFrames = 0
    @ObservationIgnored private(set) var pointRequestCount = 0
    @ObservationIgnored private var hasPosition = false
    @ObservationIgnored var selected = true
    @ObservationIgnored var mounted = false
    @ObservationIgnored var ready = true
    @ObservationIgnored var latestGeometry: ResourceSlotsScrollGeometry?
    @ObservationIgnored private var verifiedGeometry: ResourceSlotsScrollGeometry?
    @ObservationIgnored var owners: [String: OwnerFrame] = [:]
    @ObservationIgnored var groups: [String: ResourceSlotsDiagnosticFrames] = [:]
    @ObservationIgnored var rowGroups: [String: String] = [:]
    @ObservationIgnored var availableGroups: Set<String> = []
    @ObservationIgnored var phase: Phase = .group
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored private var issuedTargets: Set<ResourceSlotsScrollTarget> = []
    @ObservationIgnored var groupDiscovery = ResourceSlotsGroupDiscovery()
    @ObservationIgnored var requestedTarget: ResourceSlotsScrollTarget?
    @ObservationIgnored var requestedOffset: CGFloat?
    @ObservationIgnored private var lastPointInput: Sample?
    @ObservationIgnored private var settledSample: Sample?
    @ObservationIgnored private var settledFrames = 0
    @ObservationIgnored private var fallbackRequired = false
    @ObservationIgnored private var headerFallback = false
    @ObservationIgnored var focusFrames = 0
    @ObservationIgnored var focusReturnAuthorized = false
    /// The responder holding keyboard focus at Back. Only a responder change after this
    /// authorization counts as user focus movement; this exact responder stays neutral.
    @ObservationIgnored private weak var focusResponder: NSResponder?
    /// The window hosting the mounted content, recorded through the presented-frame seam.
    @ObservationIgnored private weak var hostingWindow: NSWindow?
    /// Issued at every appearance and handed to every owner control with its focus observation.
    /// Only a current-generation observation is live: a stale (or nil) generation belongs to an
    /// earlier, superseded appearance and must not touch the current restoration. Deliberately
    /// observed, not `@ObservationIgnored`: a newly created owner control only re-runs
    /// `updateNSView` when a value it read has changed, so the generation must be part of the
    /// observation. It is assigned only at the `beginAppearance` lifecycle point, never in a
    /// rendering or observation path, so tracking it cannot cause a publication loop.
    private(set) var focusObservationGeneration = UUID()
    @ObservationIgnored private var loadingActive = false
    @ObservationIgnored private var loadingAnnounced = false
    @ObservationIgnored var diagnosticSequence: UInt64 = 0
    @ObservationIgnored var diagnosticConfirmedFocusID: String?
    @ObservationIgnored var diagnosticMountTarget: Anchor?
    @ObservationIgnored var diagnosticMountOffset: CGFloat?
    @ObservationIgnored var diagnosticCommandExtent: CGFloat?
    @ObservationIgnored var diagnosticReportedExtent: CGFloat?

    typealias Anchor = ResourceSlotsReadingAnchor

    enum Phase { case group, owner, point }
    struct OwnerFrame { let groupID: String; let frames: ResourceSlotsDiagnosticFrames }
    private typealias Sample = ResourceSlotsRestorationSample

    var hasAuthorizedFocusReturn: Bool { focusReturnAuthorized }

    func setSelected(_ selected: Bool) {
        if !selected, self.selected { prepareDeparture() }
        self.selected = selected
        recordDiagnostic(event: "selection")
    }

    /// Freeze synchronously before routing; outgoing layout never writes into the saved intent.
    func prepareDeparture(ownerRowID: String? = nil) {
        guard selected else { return }
        if let geometry = verifiedGeometry, !isRestoring {
            adopt(geometry)
            if let ownerRowID, let owner = owners[ownerRowID],
               let frame = coherentViewport(owner.frames, geometry: geometry) {
                retainedAnchor = Anchor(groupID: owner.groupID, rowID: ownerRowID, relativeY: frame.minY)
            }
        }
        if let ownerRowID { focusedRowID = ownerRowID }
        selected = false
        invalidateCommands()
        recordDiagnostic(event: "departure")
    }

    /// `responder` captures the keyboard responder at Back. By default it is the first
    /// responder of the content's own hosting window (recorded while mounted and kept across
    /// the departure), so the returning owner does not mistake the pre-existing focus for
    /// user movement even when another app window happens to be key.
    func authorizeFocusReturn(responder: NSResponder? = nil) {
        focusReturnAuthorized = focusedRowID != nil
        focusResponder = focusReturnAuthorized ? (responder ?? hostingWindow?.firstResponder) : nil
        recordDiagnostic(event: "focus-authorized")
    }

    /// The responder captured at Back, for the native control's neutral-responder comparison.
    var focusReturnAuthorizedResponder: NSResponder? { focusResponder }

    /// The content's own hosting window, reported by the presented-frame seam while mounted.
    /// The last known window is kept across departures, so Back can capture its responder and
    /// the retry walk never has to reach into unrelated windows of the app.
    func recordHostingWindow(_ window: NSWindow?) {
        if let window { hostingWindow = window }
    }

    /// The window hosting the mounted resource content, when one has been recorded.
    var focusReturnHostWindow: NSWindow? { hostingWindow }

    /// The user moved keyboard focus away from the pending owner return (observed by the
    /// control at attempt time or through its own resign); the return is abandoned, never
    /// stolen back. Recorded distinctly from the frame-budget exhaustion path.
    func abandonFocusReturnForUserMovement() {
        recordDiagnostic(event: "focus-user-moved")
        clearFocusReturn()
    }

    func clearFocusReturn() {
        focusReturnAuthorized = false
        focusRestorationPending = false
        focusReturnRequest = nil
        focusResponder = nil
        focusedRowID = nil
    }

    func resetForRuntime() {
        recordDiagnostic(event: "runtime-reset", finishReason: .runtimeChange)
        invalidateCommands()
        clearFocusReturn()
        retainedAnchor = nil
        retainedOffset = 0
        hasPosition = false
        verifiedGeometry = nil
        latestGeometry = nil
        owners.removeAll()
        if diagnosticObserver != nil { recordDiagnostic(event: "groups-clear-runtimeReset") }
        groups.removeAll()
        rowGroups.removeAll()
        availableGroups.removeAll()
        isRestoring = false
        restorationOutcome = nil
        resetFallbackIntent()
        position = ScrollPosition()
    }

    func reconcile(groups: [ResourceSlotsGroup], expandedResourceIDs: Set<String>) {
        availableGroups = Set(groups.map(\.id))
        rowGroups = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            (group.holders + group.waiters).map { ($0.id, group.id) }
        })
        if let id = focusedRowID, rowGroups[id] == nil { clearFocusReturn() }
        if let anchor = retainedAnchor, !availableGroups.contains(anchor.groupID) {
            retainedAnchor = nil
            fallbackRequired = true
            clearFocusReturn()
            transition(to: .point)
        } else if let anchor = retainedAnchor, let rowID = anchor.rowID,
                  rowGroups[rowID] == nil || !expandedResourceIDs.contains(anchor.groupID) {
            retainedAnchor = Anchor(groupID: anchor.groupID, rowID: nil, relativeY: 0)
            headerFallback = true
            clearFocusReturn()
            transition(to: .group)
        }
        recordDiagnostic(event: "reconcile")
    }

    func beginAppearance(ready: Bool = true) {
        if diagnosticObserver != nil {
            diagnosticMountTarget = retainedAnchor
            diagnosticMountOffset = hasPosition ? retainedOffset : nil
            diagnosticCommandExtent = nil
            diagnosticReportedExtent = nil
        }
        mounted = true
        self.ready = ready
        invalidateCommands()
        isRestoring = hasPosition
        restorationOutcome = nil
        phase = retainedAnchor == nil ? .point : .group
        latestGeometry = nil
        owners.removeAll()
        if diagnosticObserver != nil { recordDiagnostic(event: "groups-clear-beginAppearance") }
        groups.removeAll()
        issuedTargets.removeAll()
        restorationFrames = 0
        pointRequestCount = 0
        focusFrames = 0
        // A fresh observation generation per appearance: every owner control receives it, so a
        // gain on ANY owner row with the current generation is a live observation, while a
        // stale or nil generation belongs to a superseded appearance and is ignored.
        focusObservationGeneration = UUID()
        focusRestorationPending = focusReturnAuthorized && focusedRowID != nil
        if focusRestorationPending, let rowID = focusedRowID {
            // A fresh token per restoration generation: single consumption, and every deferred
            // focus observation from an earlier Back cycle is recognisable as stale.
            focusReturnRequest = ResourceSlotsFocusReturnRequest(token: UUID(), rowID: rowID)
            recordDiagnostic(event: "focus-request")
        } else {
            focusReturnRequest = nil
        }
        recordDiagnostic(event: "mount")
    }

    func endAppearance() {
        prepareDeparture()
        recordDiagnostic(event: "unmount", finishReason: .unmount)
        mounted = false
        latestGeometry = nil
        owners.removeAll()
        if diagnosticObserver != nil { recordDiagnostic(event: "groups-clear-endAppearance") }
        groups.removeAll()
        isRestoring = false
        focusRestorationPending = false
        focusReturnRequest = nil
        invalidateCommands()
    }

    func setReady(_ ready: Bool) {
        if self.ready != ready { groupDiscovery.invalidateEligibility() }
        self.ready = ready
        if !ready { latestGeometry = nil; resetSamples() }
        recordDiagnostic(event: "readiness")
    }

    func update(_ geometry: ResourceSlotsScrollGeometry, ready: Bool) {
        if diagnosticObserver != nil {
            recordContentExtent(geometry)
            if self.ready != ready { recordDiagnostic(event: ready ? "scroll-ready-input" : "scroll-not-ready-input", callbackGeometry: geometry) }
        }
        defer {
            if isRestoring || focusRestorationPending || (hasPosition && (!mounted || !selected)) {
                recordDiagnostic(event: "scroll-callback", category: .geometry, callbackGeometry: geometry)
            }
        }
        guard mounted, selected else { return }
        if self.ready != ready { groupDiscovery.invalidateEligibility() }
        self.ready = ready
        guard ready, geometry.viewportHeight > 0 else { latestGeometry = nil; resetSamples(); return }
        latestGeometry = geometry
        viewportHeight = geometry.viewportHeight
        measuredOffset = geometry.offset
        if !isRestoring { adopt(geometry) }
    }

    func updateOwner(rowID: String, groupID: String, frames: ResourceSlotsDiagnosticFrames) {
        recordTargetGeometry(target: .owner(rowID), viewport: frames.viewport, content: frames.content)
        guard mounted, selected, ready, frames.viewport.width > 0, frames.viewport.height > 0 else {
            owners.removeValue(forKey: rowID)
            return
        }
        if viewportHeight > 0, frames.viewport.maxY <= 0 || frames.viewport.minY >= viewportHeight,
           !isDiagnosticTarget(.owner(rowID)) {
            owners.removeValue(forKey: rowID)
            return
        }
        owners[rowID] = OwnerFrame(groupID: groupID, frames: frames)
        if let geometry = latestGeometry, !isRestoring { adopt(geometry) }
    }

    func updateGroup(groupID: String, frames: ResourceSlotsDiagnosticFrames) {
        recordTargetGeometry(target: .group(groupID), viewport: frames.viewport, content: frames.content)
        guard mounted, selected, ready else {
            if diagnosticObserver != nil { recordGroupUpdate(groupID: groupID, frames: frames, accepted: false) }
            return
        }
        groups[groupID] = frames
        if diagnosticObserver != nil { recordGroupUpdate(groupID: groupID, frames: frames, accepted: true) }
    }

    func removeOwner(rowID: String) { owners.removeValue(forKey: rowID) }
    func removeGroup(groupID: String) {
        if diagnosticObserver != nil {
            let previous = groups[groupID]
            recordDiagnostic(event: "group-remove", callbackTarget: .group(groupID),
                             viewport: previous?.viewport, content: previous?.content,
                             rejection: previous == nil ? "already-absent" : "removed")
        }
        groups.removeValue(forKey: groupID)
    }

    /// A delayed proxy command is rejected after consumption, phase changes or lifecycle changes.
    func consumeIDScrollRequest(_ request: ResourceSlotsIDScrollRequest) -> Bool {
        guard mounted, selected, ready, isRestoring, request == idScrollRequest,
              request.generation == generation, phase != .point else { return false }
        groupDiscovery.recordConsumption(target: request.target, geometry: latestGeometry)
        if diagnosticObserver != nil { recordCommandExtent() }
        recordDiagnostic(event: "target-command-consumed")
        idScrollRequest = nil
        return true
    }

    func presentedFrame() {
        guard mounted, selected, ready else { return }
        if isRestoring {
            restorationFrames += 1
            guard restorationFrames <= Self.maximumRestorationFrames else {
                finishFallback()
                return
            }
            if let geometry = latestGeometry {
                if fallbackRequired { finishFallback() } else { advanceRestoration(geometry) }
            }
            if isRestoring, restorationFrames == Self.maximumRestorationFrames { finishFallback() }
        } else if focusRestorationPending {
            focusFrames += 1
            if focusFrames >= Self.maximumRestorationFrames {
                recordDiagnostic(event: "focus-budget-exhausted", finishReason: .boundedFallback)
                clearFocusReturn()
            }
        }
        if isRestoring || focusRestorationPending { recordDiagnostic(event: "presented-frame", category: .geometry) }
    }

    func cancelRestorationForUser() {
        guard mounted else { return }
        recordDiagnostic(event: "user-cancel", finishReason: .userCancellation)
        isRestoring = false
        restorationOutcome = .userCancelled
        resetFallbackIntent()
        clearFocusReturn()
        invalidateCommands()
        if let geometry = latestGeometry { adopt(geometry, allowMissingAnchor: true) }
    }

    func visibleOwnerFrame(rowID: String) -> (frame: CGRect, offset: CGFloat)? {
        guard let geometry = latestGeometry, let owner = owners[rowID],
              let frame = coherentViewport(owner.frames, geometry: geometry), isVisible(frame, geometry: geometry) else { return nil }
        return (frame, geometry.offset)
    }

    func canRestoreFocus(rowID: String, frame: CGRect, geometryOffset: CGFloat? = nil) -> Bool {
        let currentFrame = geometryOffset.map { abs($0 - measuredOffset) < 1 } ?? true
        return mounted && selected && !isRestoring && focusRestorationPending && focusedRowID == rowID && currentFrame
            && frame.width > 0 && frame.height > 0 && frame.maxY > 0 && frame.minY < viewportHeight
    }

    /// Token-verified completion. Only a control that verified `window.firstResponder === view`
    /// under the current token may consume the restoration; an observation never can.
    func acknowledgeFocusReturn(token: UUID) {
        guard let request = focusReturnRequest, request.token == token, focusRestorationPending else {
            recordDiagnostic(event: "focus-acknowledge-ignored")
            return
        }
        focusReturnRequest = nil
        focusRestorationPending = false
        focusReturnAuthorized = false
        focusResponder = nil
        diagnosticConfirmedFocusID = request.rowID
        recordDiagnostic(event: "focus-restored", finishReason: .success)
    }

    /// A deferred `becomeFirstResponder` observation from the native control, carrying the
    /// appearance generation the control was configured under. It never completes a
    /// restoration on its own.
    func observeFocusGain(rowID: String, generation: UUID?, token: UUID?) {
        applyFocusGain(rowID: rowID, generation: generation, token: token)
    }

    /// A deferred `resignFirstResponder` observation from the native control. A stale
    /// callback from an earlier appearance or Back cycle is ignored; it never cancels a newer
    /// pending restoration by row identity alone.
    func observeFocusLoss(rowID: String, generation: UUID?, token: UUID?) {
        applyFocusLoss(rowID: rowID, generation: generation, token: token)
    }

    private func applyFocusGain(rowID: String, generation: UUID?, token: UUID?) {
        defer { recordDiagnostic(event: "focus-observed") }
        // The appearance generation decides whether the observation is live at all: only the
        // current generation can move focus intent. The restoration token stays the only thing
        // that completes a restoration.
        guard let generation, generation == focusObservationGeneration else { return }
        // A live gain on a different owner row while restoring is real user focus movement.
        if isRestoring, rowID != focusedRowID {
            cancelRestorationForUser()
            focusedRowID = rowID
            return
        }
        guard rowID == focusedRowID, let token, focusReturnRequest?.token == token else { return }
        diagnosticConfirmedFocusID = rowID
    }

    private func applyFocusLoss(rowID: String, generation: UUID?, token: UUID?) {
        defer { recordDiagnostic(event: "focus-observed") }
        // Resign only reports nil while the row is still the focused row.
        guard rowID == focusedRowID else { return }
        guard let generation, generation == focusObservationGeneration,
              let token, focusReturnRequest?.token == token else { return }
        // The control owning the current request lost keyboard focus before completing it:
        // the user moved focus; it is never stolen back.
        if isRestoring {
            cancelRestorationForUser()
        } else {
            abandonFocusReturnForUserMovement()
        }
    }

    func takeLoadingAnnouncement(isLoading: Bool) -> Bool {
        guard isLoading else { loadingActive = false; return false }
        if !loadingActive { loadingActive = true; loadingAnnounced = false }
        guard !loadingAnnounced else { return false }
        loadingAnnounced = true
        return true
    }

    private func advanceRestoration(_ geometry: ResourceSlotsScrollGeometry) {
        switch phase {
        case .group: materializeGroup(geometry)
        case .owner: materializeOwner(geometry)
        case .point: restorePoint(geometry)
        }
    }

    private func materializeGroup(_ geometry: ResourceSlotsScrollGeometry) {
        guard let anchor = retainedAnchor else { transition(to: .point); return }
        let target = ResourceSlotsScrollTarget.group(anchor.groupID)
        if issueTargetIfNeeded(target, geometry: geometry) { return }
        if groupDiscovery.qualifiesForRetry(target: target, geometry: geometry,
                                           targetIsMissing: groups[anchor.groupID] == nil, hasPendingCommand: idScrollRequest != nil) {
            groupDiscovery.recordRetry(target: target, geometry: geometry)
            requestTarget(target)
            return
        }
        guard idScrollRequest == nil,
              qualifiedSample(groups[anchor.groupID], geometry: geometry) else {
            if diagnosticObserver != nil {
                recordDiagnostic(event: "group-pending", category: .geometry, callbackTarget: target,
                                 rejection: groupPendingReason(groupID: anchor.groupID, geometry: geometry))
            }
            return
        }
        transition(to: anchor.rowID == nil ? .point : .owner)
    }

    private func materializeOwner(_ geometry: ResourceSlotsScrollGeometry) {
        guard let rowID = retainedAnchor?.rowID else { transition(to: .point); return }
        if issueTargetIfNeeded(.owner(rowID), geometry: geometry) { return }
        guard idScrollRequest == nil,
              qualifiedSample(owners[rowID]?.frames, geometry: geometry) else {
            recordDiagnostic(event: "owner-pending", category: .geometry, rejection: "missing-or-incoherent-target")
            return
        }
        transition(to: .point)
    }

    private func issueTargetIfNeeded(_ target: ResourceSlotsScrollTarget, geometry: ResourceSlotsScrollGeometry) -> Bool {
        guard issuedTargets.insert(target).inserted else { return false }
        groupDiscovery.recordInitialIssue(target: target, geometry: geometry)
        requestTarget(target)
        return true
    }

    private func requestTarget(_ target: ResourceSlotsScrollTarget) {
        resetSamples()
        requestedTarget = target
        idScrollRequest = .init(id: UUID(), generation: generation, target: target)
        recordDiagnostic(event: "target-request")
    }

    private func restorePoint(_ geometry: ResourceSlotsScrollGeometry) {
        let frames = pointFrames()
        if retainedAnchor != nil {
            guard let frames, coherentViewport(frames, geometry: geometry) != nil else {
                resetSamples()
                recordDiagnostic(event: "point-pending", category: .geometry, rejection: "missing-or-incoherent-target")
                return
            }
        }
        let sample = Sample(geometry: geometry, frames: frames)
        guard observeSettled(sample) else { return }
        let desired = desiredPoint(frames: frames) ?? retainedOffset
        let clamped = geometry.clamped(desired)
        if let requestedOffset, abs(geometry.offset - requestedOffset) < 1, abs(clamped - requestedOffset) < 1 {
            let boundary = abs(desired - clamped) >= 1 || headerFallback
            finishRestoration(geometry, outcome: boundary ? .boundaryAligned : .exact)
            return
        }
        guard sample != lastPointInput else { return }
        guard pointRequestCount < Self.maximumPointRequests else { finishFallback(); return }
        lastPointInput = sample
        requestedOffset = clamped
        pointRequestCount += 1
        if diagnosticObserver != nil { recordCommandExtent() }
        recordDiagnostic(event: "point-request")
        position.scrollTo(y: clamped)
        resetSamples()
    }

    private func pointFrames() -> ResourceSlotsDiagnosticFrames? {
        guard let anchor = retainedAnchor else { return nil }
        if let rowID = anchor.rowID { return owners[rowID]?.frames }
        return groups[anchor.groupID]
    }

    private func desiredPoint(frames: ResourceSlotsDiagnosticFrames?) -> CGFloat? {
        guard let anchor = retainedAnchor, let content = frames?.content else { return nil }
        return content.minY - anchor.relativeY
    }

    private func qualifiedSample(_ frames: ResourceSlotsDiagnosticFrames?, geometry: ResourceSlotsScrollGeometry) -> Bool {
        guard let frames, let frame = coherentViewport(frames, geometry: geometry), isVisible(frame, geometry: geometry) else {
            resetSamples()
            return false
        }
        return observeSettled(.init(geometry: geometry, frames: frames))
    }

    private func observeSettled(_ sample: Sample) -> Bool {
        if settledSample == sample { settledFrames += 1 } else { settledSample = sample; settledFrames = 1 }
        return settledFrames >= 2
    }

    private func coherentViewport(_ frames: ResourceSlotsDiagnosticFrames, geometry: ResourceSlotsScrollGeometry) -> CGRect? {
        frames.coherentViewport(geometry: geometry, coordinateSpaceDelta: Self.coordinateSpaceDelta)
    }

    private func isVisible(_ frame: CGRect, geometry: ResourceSlotsScrollGeometry) -> Bool {
        frame.resourceSlotsIntersects(viewportHeight: geometry.viewportHeight)
    }

    private func transition(to phase: Phase) {
        groupDiscovery.invalidateEligibility()
        self.phase = phase
        idScrollRequest = nil
        requestedOffset = nil
        resetSamples()
        recordDiagnostic(event: "phase-change")
    }

    private func invalidateCommands() {
        generation = UUID()
        groupDiscovery.endGeneration()
        idScrollRequest = nil
        requestedOffset = nil
        requestedTarget = nil
        lastPointInput = nil
        resetSamples()
    }

    private func resetFallbackIntent() { fallbackRequired = false; headerFallback = false }
    private func resetSamples() { settledSample = nil; settledFrames = 0 }

    private func finishFallback() {
        restorationOutcome = .fallback
        recordDiagnostic(event: "scroll-finished", finishReason: .boundedFallback)
        isRestoring = false
        resetFallbackIntent()
        clearFocusReturn()
        retainedAnchor = nil
        invalidateCommands()
        if let geometry = latestGeometry { adopt(geometry, allowMissingAnchor: true) }
    }

    private func finishRestoration(_ geometry: ResourceSlotsScrollGeometry, outcome: ResourceSlotsRestorationOutcome) {
        restorationOutcome = outcome
        recordDiagnostic(event: "scroll-finished", finishReason: outcome == .exact ? .success : .boundaryAligned)
        isRestoring = false
        resetFallbackIntent()
        invalidateCommands()
        adopt(geometry)
    }

    private func adopt(_ geometry: ResourceSlotsScrollGeometry, allowMissingAnchor: Bool = false) {
        guard selected else { return }
        let visible = owners.compactMap { id, owner -> (String, OwnerFrame, CGRect)? in
            guard let frame = coherentViewport(owner.frames, geometry: geometry), isVisible(frame, geometry: geometry) else { return nil }
            return (id, owner, frame)
        }
        if !allowMissingAnchor, retainedAnchor?.rowID != nil, visible.isEmpty { return }
        retainedOffset = geometry.clamped(geometry.offset)
        verifiedGeometry = geometry
        hasPosition = true
        if let owner = visible.min(by: { abs($0.2.minY) < abs($1.2.minY) }) {
            retainedAnchor = Anchor(groupID: owner.1.groupID, rowID: owner.0, relativeY: owner.2.minY)
        }
    }

}
