import AppKit
import HfUI
import Observation
import SwiftUI

// MARK: - ResourceSlotsContent

struct ResourceSlotsContent: View {
    let presentation: ResourceSlotsPresentation
    @Bindable var readingState: ResourceSlotsReadingState
    @FocusState private var focusedRowID: String?
    @State private var ownerFrames = ResourceSlotsOwnerFrames()
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
                ownerFrames.values.removeAll()
            case .idle, .animating: break
            @unknown default: break
            }
        }
        .background {
            ResourceSlotsRestorationFrames(active: !isLoading && (readingState.isRestoring || readingState.focusRestorationPending)) {
                readingState.presentedFrame()
                restoreFocusIfReady()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background(Color.windowBG)
        .onAppear {
            readingState.beginAppearance(ready: !isLoading)
            announceLoadingIfNeeded()
        }
        .onDisappear {
            readingState.endAppearance()
            ownerFrames.values.removeAll()
        }
        .onChange(of: isLoading) { _, _ in
            readingState.setReady(!isLoading)
            announceLoadingIfNeeded()
        }
        .onChange(of: readingState.isRestoring) { _, _ in restoreFocusIfReady() }
        .onChange(of: focusedRowID) { _, id in
            if let id {
                readingState.focusedRowID = id
                readingState.didRestoreFocus()
            }
        }
        .accessibilityLabel(isLoading ? "Loading resource slots" : "Resource slots")
    }

    private func restoreFocusIfReady() {
        guard !isLoading, let id = readingState.focusedRowID, let entry = ownerFrames.values[id],
              readingState.canRestoreFocus(rowID: id, frame: entry.frame, geometryOffset: entry.offset) else { return }
        focusedRowID = id
        readingState.didRestoreFocus()
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
                ForEach(groups) { group in
                    ResourceSlotsCard(group: group, expanded: expandedResourceIDs.contains(group.id),
                                      expandedBlockerIDs: expandedBlockerIDs,
                                      onToggle: { onToggleResource(group.id) },
                                      onToggleBlockers: onToggleBlockers, focusedRowID: $focusedRowID,
                                      trackedOwnerID: readingState.focusRestorationPending ? readingState.focusedRowID : nil,
                                      onOwnerGeometry: { id, frame in
                                          guard readingState.focusRestorationPending, readingState.focusedRowID == id else { return }
                                          ownerFrames.values[id] = .init(frame: frame, offset: readingState.measuredOffset)
                                          restoreFocusIfReady()
                                      },
                                      onOpenOwner: { id in
                                          readingState.focusedRowID = id
                                          onOpenOwner(id)
                                      })
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
    let focusedRowID: FocusState<String?>.Binding
    let trackedOwnerID: String?
    let onOwnerGeometry: (String, CGRect) -> Void
    let onOpenOwner: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { _ in onToggle() })) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Divider()
                    sectionHeading(group.holderHeading)
                    if let message = group.emptyHolderMessage {
                        Text(message).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).padding(.vertical, 10)
                    }
                    ForEach(group.holders) { row in owner(row) }
                    if let heading = group.waiterHeading { sectionHeading(heading) }
                    ForEach(group.waiters) { row in owner(row) }
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
            .disclosureGroupStyle(ResourceSlotsDisclosureStyle())
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
                    Button(action.label) { onOpenOwner(row.id) }
                        .buttonStyle(MonitorButtonStyle(.tinted))
                        .focused(focusedRowID, equals: row.id)
                        .accessibilityLabel(action.label + " " + row.title + (row.title == row.ownerID ? "" : ", " + row.ownerID))
                        .onGeometryChange(for: CGRect.self) { geometry in
                            trackedOwnerID == row.id ? geometry.frame(in: .named("resourceSlotsViewport")) : .zero
                        } action: { frame in
                            if trackedOwnerID == row.id { onOwnerGeometry(row.id, frame) }
                        }
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            Divider()
        }
        .id(row.id)
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

// The native disclosure retains its semantics while the chevron has fixed, undistorted bounds.
struct ResourceSlotsDisclosureStyle: DisclosureGroupStyle {
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
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                DisclosureGroup(isExpanded: Binding(
                    get: { configuration.isExpanded },
                    set: { configuration.isExpanded = $0 }
                )) {
                    EmptyView()
                } label: {
                    configuration.label
                }
                .disclosureGroupStyle(.automatic)
            }
            if configuration.isExpanded { configuration.content.disclosureGroupStyle(.automatic) }
        }
    }
}
