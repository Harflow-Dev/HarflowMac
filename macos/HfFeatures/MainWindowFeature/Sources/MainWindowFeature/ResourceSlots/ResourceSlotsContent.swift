import AppKit
import HfUI
import Observation
import SwiftUI

// MARK: - ResourceSlotsContent

struct ResourceSlotsContent: View {
    let presentation: ResourceSlotsPresentation
    @Bindable var readingState: ResourceSlotsReadingState
    let expandedResourceIDs: Set<String>
    let expandedBlockerIDs: Set<String>
    let onToggleResource: (String) -> Void
    let onToggleBlockers: (String) -> Void
    let onOpenOwner: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var motionOverride
    @Environment(\.shimmerReduceMotionOverride) private var shimmerOverride

    private var reduceMotion: Bool { motionOverride ?? shimmerOverride ?? systemReduceMotion }
    private var isLoading: Bool {
        if case .loading = presentation.state { return true }
        return false
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollSurface
                .onChange(of: readingState.idScrollRequest) { _, request in
                    guard let request, readingState.consumeIDScrollRequest(request) else { return }
                    proxy.scrollTo(request.target, anchor: .top)
                }
        }
    }

    private var scrollSurface: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Resource slots")
.font(.hf(.title, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                SkeletonContent(isLoading: isLoading) {
                    ResourceSlotsSkeleton(reduceMotion: reduceMotion)
                } content: {
                    content
                }
                .environment(\.hfReduceMotionOverride, reduceMotion)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .coordinateSpace(name: "resourceSlotsDiagnosticContent")
        }
        .scrollPosition($readingState.position)
        .coordinateSpace(name: "resourceSlotsViewport")
        .onScrollGeometryChange(for: ResourceSlotsScrollGeometry.self) { geometry in
            .init(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                  viewportHeight: geometry.containerSize.height, topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom)
        } action: { _, geometry in
            readingState.update(geometry, ready: !isLoading)
            restoreFocusIfReady()
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating:
                readingState.cancelRestorationForUser()
            case .idle, .animating: break
            @unknown default: break
            }
        }
        .background {
            ResourceSlotsRestorationFrames(active: !isLoading && (readingState.isRestoring || readingState.focusRestorationPending),
                                           onWindow: { readingState.recordHostingWindow($0) }) {
                readingState.presentedFrame()
                restoreFocusIfReady()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background(Color.windowBG)
        .onAppear {
            reconcileReadingTargets()
            readingState.beginAppearance(ready: !isLoading)
            announceLoadingIfNeeded()
        }
        .onDisappear {
            readingState.endAppearance()
        }
        .onChange(of: isLoading) { _, _ in
            readingState.setReady(!isLoading)
            announceLoadingIfNeeded()
        }
        .onChange(of: presentation) { _, _ in reconcileReadingTargets() }
        .onChange(of: expandedResourceIDs) { _, _ in reconcileReadingTargets() }
        .onChange(of: readingState.isRestoring) { _, _ in restoreFocusIfReady() }
        .accessibilityLabel(isLoading ? "Loading resource slots" : "Resource slots")
    }

    private func reconcileReadingTargets() {
        guard case let .ready(_, groups) = presentation.state else { return }
        readingState.reconcile(groups: groups, expandedResourceIDs: expandedResourceIDs)
    }

    /// A pending focus-return token is retried across every realized owner control of the
    /// window hosting this content, like `CallerApprovalNativeFocus.retry(in:)`; readiness,
    /// geometry and presented-frame paths all funnel here. The control itself owns the
    /// attempt and its verification.
    private func restoreFocusIfReady() {
        guard readingState.focusReturnRequest != nil,
              let content = readingState.focusReturnHostWindow?.contentView else { return }
        ResourceSlotsOwnerFocus.retry(in: content)
    }

    private func announceLoadingIfNeeded() {
        guard readingState.takeLoadingAnnouncement(isLoading: isLoading) else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: "Loading resource slots", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @ViewBuilder private var content: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(presentation.qualifiers) { qualifier in
                Text(qualifier.text)
                    .font(.hf(.secondary))
                    .foregroundStyle(qualifier.isWarning ? Color.warningFG : Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
            }
            switch presentation.state {
            case .loading:
                EmptyView()
            case let .ready(summary, groups):
                Text(summary)
.font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                    .padding(.bottom, 4)
                ForEach(groups, id: \.scrollTarget) { group in
                    ResourceSlotsCard(group: group, expanded: expandedResourceIDs.contains(group.id),
                                      expandedBlockerIDs: expandedBlockerIDs,
                                      onToggle: {
                                          readingState.cancelRestorationForUser()
                                          onToggleResource(group.id)
                                      },
                                      onToggleBlockers: { id in
                                          readingState.cancelRestorationForUser()
                                          onToggleBlockers(id)
                                      }, readingState: readingState,
                                      onOwnerGeometry: { id, frames in
                                          readingState.updateOwner(rowID: id, groupID: group.id, frames: frames)
                                          restoreFocusIfReady()
                                      },
                                      onOwnerDisappear: { readingState.removeOwner(rowID: $0) },
                                      onOpenOwner: onOpenOwner)
                        .onGeometryChange(for: ResourceSlotsDiagnosticFrames.self) { geometry in
                            .init(viewport: geometry.frame(in: .named("resourceSlotsViewport")),
                                  content: geometry.frame(in: .named("resourceSlotsDiagnosticContent")))
                        } action: { frames in
                            readingState.updateGroup(groupID: group.id, frames: frames)
                        }
                        .onDisappear { readingState.removeGroup(groupID: group.id) }
                }
            case let .empty(title, message), let .notEnabled(title, message),
                 let .unsupported(title, message), let .unavailable(title, message):
                VStack(spacing: 6) {
                    Text(title).font(.hf(.headline, weight: .semibold)).foregroundStyle(Color.primaryText)
                    Text(message).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            }
        }
        .padding(.top, 4)
    }
}

private struct ResourceSlotsCard: View {
    let group: ResourceSlotsGroup
    let expanded: Bool
    let expandedBlockerIDs: Set<String>
    let onToggle: () -> Void
    let onToggleBlockers: (String) -> Void
    let readingState: ResourceSlotsReadingState
    let onOwnerGeometry: (String, ResourceSlotsDiagnosticFrames) -> Void
    let onOwnerDisappear: (String) -> Void
    let onOpenOwner: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { _ in onToggle() })) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The header keeps its 14pt inset below the summary when expanded, as it
                    // does collapsed (design: the toggle's 14px padding above the body hairline).
                    Divider().padding(.top, 14)
                    sectionHeading(group.holderHeading)
                    if let message = group.emptyHolderMessage {
                        Text(message).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).padding(.vertical, 10)
                    }
                    ForEach(group.holders, id: \.scrollTarget) { row in owner(row) }
                    if let heading = group.waiterHeading { sectionHeading(heading) }
                    ForEach(group.waiters, id: \.scrollTarget) { row in owner(row) }
                }
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "lock").frame(width: 17, height: 17).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title).font(.hf(.headline, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(group.capacitySummary).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .disclosureGroupStyle(ResourceSlotsDisclosureStyle(identifier: "resource-slots-group-" + group.id,
                                                               label: group.title + ", " + group.capacitySummary))
            .tint(Color.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
.font(.hf(.secondary, weight: .semibold))
.foregroundStyle(Color.secondaryText)
            .padding(.top, 14)
.padding(.bottom, 2)
    }

    /// The owner action's native control: the reading state's token is the single-use focus
    /// intent, and every observation and acknowledgement flows back through the same state.
    private func ownerButton(row: ResourceSlotsOwner, action: ResourceSlotsOwner.Action) -> some View {
        ResourceSlotsOwnerButton(
            title: action.label,
            label: action.label + " " + row.title + (row.title == row.ownerID ? "" : ", " + row.ownerID),
            identifier: "resource-slots-owner-" + row.id,
            generation: readingState.focusObservationGeneration,
            token: readingState.focusReturnRequest?.rowID == row.id ? readingState.focusReturnRequest?.token : nil,
            isReady: {
                guard let entry = readingState.visibleOwnerFrame(rowID: row.id) else { return false }
                return readingState.canRestoreFocus(rowID: row.id, frame: entry.frame, geometryOffset: entry.offset)
            },
            authorizedResponder: { readingState.focusReturnAuthorizedResponder },
            acknowledge: { readingState.acknowledgeFocusReturn(token: $0) },
            observeFocusGain: { generation, token in
                readingState.observeFocusGain(rowID: row.id, generation: generation, token: token)
            },
            observeFocusLoss: { generation, token in
                readingState.observeFocusLoss(rowID: row.id, generation: generation, token: token)
            },
            userMovedFocus: { readingState.abandonFocusReturnForUserMovement() },
            action: { onOpenOwner(row.id) }
        )
    }

    private func owner(_ row: ResourceSlotsOwner) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let position = row.position {
                    Text(position)
.font(.hf(.secondary, weight: .semibold))
.padding(5)
                        .background(Color.neutralFill, in: RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
.font(.hf(.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(([row.status, row.since, row.title == row.ownerID ? nil : row.ownerID, row.detail].compactMap(\.self)).joined(separator: " · "))
                        .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let blockers = row.blockers {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedBlockerIDs.contains(row.id) },
                            set: { _ in onToggleBlockers(row.id) }
                        )) {
                            ResourceSlotsBlockerContent(blockers: blockers).padding(.top, 6)
                        } label: {
                            Text("Blocking details")
                                .accessibilityLabel("Blocking details for \(row.title)")
                        }
                        .font(.hf(.secondary))
                        .tint(Color.accentLink)
                        .disclosureGroupStyle(.automatic)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let action = row.action {
                    ownerButton(row: row, action: action)
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            Divider()
        }
        .onGeometryChange(for: ResourceSlotsDiagnosticFrames.self) { geometry in
            .init(viewport: geometry.frame(in: .named("resourceSlotsViewport")),
                  content: geometry.frame(in: .named("resourceSlotsDiagnosticContent")))
        } action: { frames in
            onOwnerGeometry(row.id, frames)
        }
        .onDisappear { onOwnerDisappear(row.id) }
    }
}

struct ResourceSlotsBlockerContent: View {
    let blockers: ResourceSlotsBlockers
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            Text("Blocking details").font(.hf(.secondary, weight: .semibold))
            ForEach(blockers.rows) { row in
                Text("• \(row.text)").font(.hf(.secondary)).fixedSize(horizontal: false, vertical: true)
            }
            if let note = blockers.note { Text(note).font(.hf(.secondary)).foregroundStyle(Color.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
    }
}

// The native header button exposes expansion state while retaining the approved trailing chevron.
struct ResourceSlotsDisclosureStyle: DisclosureGroupStyle {
    let identifier: String
    let label: String
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack {
                    configuration.label
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(identifier)
            if configuration.isExpanded { configuration.content.disclosureGroupStyle(.automatic) }
        }
    }
}
