import MonitorCore
import PbUI
import SwiftUI

// MARK: - ActivityFeedWindow

/// UI pages are independent of the bounded event reader's pages.
enum ActivityFeedWindow {
    static let pageSize = 100
    static let threshold: CGFloat = 200

    static func firstIndex(ids: [String], retainedID: String?) -> Int {
        retainedID.flatMap { ids.firstIndex(of: $0) } ?? max(0, ids.count - pageSize)
    }

    static func olderBoundary(ids: [String], retainedID: String?) -> String? {
        let first = firstIndex(ids: ids, retainedID: retainedID)
        guard first > 0 else { return nil }
        return ids[max(0, first - pageSize)]
    }

    static func shouldLoad(offset: CGFloat, viewport: CGFloat, eligibility: ActivityFeedEligibility) -> Bool {
        eligibility.positioned && !eligibility.restoring && eligibility.visible && !eligibility.loading
            && eligibility.error == nil && viewport > 0 && offset <= threshold
    }
}

/// Bounds automatic filling when collapsed or filtered pages do not grow the viewport.
struct ActivityShortFillBudget {
    private(set) var remaining = 1
    mutating func replenish() { remaining = 1 }
    mutating func consume(content: CGFloat, viewport: CGFloat) -> Bool {
        guard content <= viewport + 1 else { return true }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

// MARK: - ActivityFeedEligibility

struct ActivityFeedEligibility {
    var positioned = false
    var restoring = false
    var visible = true
    var loading = false
    var error: String?
}

// MARK: - ActivityFeedPosition

@MainActor
private final class ActivityFeedPosition {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    /// Measurements support reading restoration without invalidating the lazy feed's view graph.
    var frames: [String: CGRect] = [:]
    let measurements = ActivityRowMeasurements()
    var pagingTask: Task<Void, Never>?
}

// MARK: - ActivityFeedKey

private struct ActivityFeedKey: Equatable {
    let nativeViewportReady: Bool
    let realizedLastRowID: String?
    let rows: [ActivityRow]
    let tail: ActivityFeedTail
    let showsPromptBubble: Bool
    let expandedGroups: Set<String>
    let viewport: CGSize
    let history: EventHistoryState
    let loading: Bool
    let visible: Bool
    let paginationRevision: Int
    let restoring: Bool
}

// MARK: - ActivityFeedTail

struct ActivityFeedTail: Equatable {
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var children: [TaskDetailTimelineChild] = []
}

// MARK: - ActivityFeedView

/// Shared reading, progressive reveal and older-page behavior across activity surfaces.
struct ActivityFeedView<Tail: View>: View {
    let rows: [ActivityRow]
    let start: Date?
    let history: EventHistoryState
    let isLoading: Bool
    var tailValue = ActivityFeedTail()
    var paginationRevision = 0
    var isVisible = true
    var emptyText: String?
    var horizontalPadding: CGFloat = 0
    /// Task detail owns its started-row prompt; Parallel owns it in the toggled column header.
    var showsPromptBubble = true
    let state: ParallelColumnUIState
    let onLoadMore: (() -> Bool)?
    @ViewBuilder let tail: () -> Tail

    @State private var measurementGeneration = 0
    @State private var viewportSize: CGSize = .zero
    @State private var nativeViewportReady = false
    @State private var realizedLastRowID: String?
    @State private var position = ActivityFeedPosition()
    @State private var pendingReadingCapture = true
    @State private var positioned = false
    @State private var followingLayout = true
    @State private var restoring = true
    @State private var targetOffset: CGFloat?
    @State private var restorationRowWidth: CGFloat?
    @State private var restorationTiming: UInt64?
    @State private var shortFillBudget = ActivityShortFillBudget()
    @State private var waitingForPage = false
    @State private var requestedIDs: [String] = []
    @State private var rejectedPageIDs: [String]?
    @State private var sawLoading = false
    @State private var seenIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var bottomID: String { "activity-feed-bottom" }
    private var ids: [String] { rows.map(\.id) }
    private var shown: [ActivityRow] {
        Array(rows.dropFirst(ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    historyHeader
                    if let emptyText { Text(emptyText).font(.pb(.body)).foregroundStyle(Color.secondaryText) }
                    ForEach(shown) { row in
                        rowView(row)
                            .id(row.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ActivityRowGeometry(
                                generation: measurementGeneration,
                                measurements: position.measurements
                            ) { [generation = measurementGeneration] frame in
                                guard generation == measurementGeneration else { return }
                                guard position.frames[row.id] != frame else { return }
                                position.frames[row.id] = frame
                                if row.id == shown.last?.id, realizedLastRowID != row.id { realizedLastRowID = row.id }
                                scheduleReadingUpdate()
                            })
                            .pbFadeIn(animate: positioned && !restoring && state.followLive.isFollowing && !seenIDs.contains(row.id))
                            .onAppear { seenIDs.insert(row.id) }
                    }
                    tail()
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 12)
                .coordinateSpace(name: "activity-feed-document")
                .background(ParallelScrollObserver(axis: .vertical, restorationOffset: targetOffset, restorationActive: restoring || followingLayout,
                                                   onViewportSize: observeViewport, onUpwardIntent: upwardIntent) { offset, content, viewport in
                    if positioned, !restoring, abs(content - position.content) < 0.5, position.viewport == viewport,
                       abs(offset - position.offset) > 0.5 {
                        pendingReadingCapture = true
                        if offset < position.offset { shortFillBudget.replenish() }
                    }
                    if positioned, !restoring, abs(content - position.content) < 0.5, position.viewport == viewport, offset < position.offset - 0.5 {
                        state.followLive.observe(offset: offset, contentHeight: content, viewportHeight: viewport)
                        if !state.followLive.isFollowing { targetOffset = nil }
                    }
                    if state.followLive.isFollowing, position.content != content || position.viewport != viewport { followingLayout = true }
                    position.measurements.scheduleMeasurements()
                    position.offset = offset
                    position.content = content
                    position.viewport = viewport
                    // Native attachment can follow the first keyed task. Retry proxy positioning
                    // once the inner scroll view has a usable viewport.
                    let ready = viewport > 0
                    if nativeViewportReady != ready { nativeViewportReady = ready }
                    scheduleReadingUpdate()
                })
            }
            .task(id: ActivityFeedKey(nativeViewportReady: nativeViewportReady, realizedLastRowID: realizedLastRowID, rows: shown, tail: tailValue, showsPromptBubble: showsPromptBubble,
                                     expandedGroups: state.expandedGroups, viewport: viewportSize, history: history,
                                     loading: isLoading, visible: isVisible, paginationRevision: paginationRevision, restoring: restoring)) {
                await settle(proxy)
            }
            .onDisappear { position.pagingTask?.cancel(); position.pagingTask = nil }
            .onChange(of: rows) { old, next in
                if state.followLive.isFollowing { followingLayout = true }
                preserveRegroupedAnchor(old: old, next: next)
                if !state.followLive.isFollowing { beginRestoration() }
                if waitingForPage, requestedIDs != ids {
                    state.retainedFirstID = next.first?.id
                    waitingForPage = false
                }
            }
            .onChange(of: tailValue) { _, _ in
                if state.followLive.isFollowing { followingLayout = true } else { beginRestoration() }
            }
            .onChange(of: paginationRevision) { _, _ in
                rejectedPageIDs = nil
                waitingForPage = false
                sawLoading = false
                if !state.followLive.isFollowing { beginRestoration() }
                if !rows.isEmpty { state.retainedFirstID = rows.first?.id }
            }
            .onChange(of: history) { _, next in
                rejectedPageIDs = nil
                if waitingForPage {
                    sawLoading = sawLoading || next.isLoading
                    if !next.isLoading, sawLoading || next.error != nil || !next.hasMore {
                        waitingForPage = false
                        restoring = !state.followLive.isFollowing
                    }
                }
            }
        }
    }

    @ViewBuilder private var historyHeader: some View {
        if history.isLoading || waitingForPage {
            LoadingLabel("Loading activity…")
        } else if let error = history.error {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Button("Retry older activity") { requestPage(retry: true) }.buttonStyle(.link)
            }
        } else if !history.hasMore, ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID) == 0, !rows.isEmpty {
            Text("Beginning of activity").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private func rowView(_ row: ActivityRow) -> some View {
        switch row {
        case .toolGroup(let group):
            ToolGroupCardView(group: group, start: start, isExpanded: state.expandedGroups.contains(group.id)) {
                shortFillBudget.replenish()
                beginRestoration()
                withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) {
                    if !state.expandedGroups.insert(group.id).inserted { state.expandedGroups.remove(group.id) }
                }
            }
        case .single(let row):
            switch row.kind {
            case .separator(let text): TurnSeparatorRow(text: text, timestamp: row.timestamp)
            case .item(let item): TimelineRow(model: TimelineRowModel(item: item, start: start, live: row.live, showsPromptBubble: showsPromptBubble))
            }
        }
    }

    private var currentWidthFrames: [String: CGRect] {
        guard let anchor = state.anchor, let measuredWidth = position.frames[anchor.id]?.width else { return position.frames }
        return position.frames.filter { abs($0.value.width - measuredWidth) < 1 }
    }

    private func captureAnchor() {
        guard pendingReadingCapture || state.followLive.isFollowing || state.anchor == nil else { return }
        if let anchor = ParallelVerticalAnchor.capture(ids: shown.map(\.id), frames: currentWidthFrames,
            viewportHeight: position.viewport, offset: position.offset) {
            state.anchor = anchor
            pendingReadingCapture = false
        }
    }

    private func observeViewport(_ size: CGSize) {
        guard size != viewportSize else { return }
        if positioned, !state.followLive.isFollowing {
            if viewportSize.width > 0, abs(size.width - viewportSize.width) > 0.5 {
                restorationRowWidth = max(0, size.width - 2 * horizontalPadding)
                let width = restorationRowWidth ?? 0
                position.frames = position.frames.filter { $0.key == state.anchor?.id || abs($0.value.width - width) < 1 }
            }
            beginRestoration()
        }
        if state.followLive.isFollowing { followingLayout = true }
        viewportSize = size
    }

    private func settle(_ proxy: ScrollViewProxy) async {
        await Task.yield()
        guard !Task.isCancelled, !isLoading, position.viewport > 0 else { return }
        if state.followLive.isFollowing {
            // Realize actual content before trusting the lazy document's estimated height.
            if !positioned, let last = shown.last, position.frames[last.id] == nil {
                targetOffset = nil
                proxy.scrollTo(last.id, anchor: .bottom)
                return // Its native measurement restarts this task through realizedLastRowID.
            }
            if !positioned || followingLayout {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            followingLayout = true
            targetOffset = max(0, position.content - position.viewport)
        } else if restoring {
            if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)) {
                let staleWidth = restorationRowWidth.map { abs((position.frames[id]?.width ?? -1) - $0) > 1 } ?? false
                if position.frames[id] == nil || staleWidth {
                    proxy.scrollTo(id, anchor: .top)
                    await Task.yield()
                }
            }
            restoreAnchor()
        }
        observePosition()
        scheduleReadingUpdate()
    }

    private func observePosition() {
        let timing = MonitorMetrics.begin()
        defer { MonitorMetrics.end(timing, stage: .activityViewport) }
        guard !isLoading, position.viewport > 0 else { return }
        finishRestoration()
        guard positioned, !restoring, !followingLayout else { return }
        if let restorationTiming {
            MonitorMetrics.end(restorationTiming, stage: .activityScrollRestore)
            self.restorationTiming = nil
        }
        state.scrollOffset = position.offset
        captureAnchor()
        let wasFollowing = state.followLive.isFollowing
        if !shown.isEmpty {
            state.followLive.observe(offset: position.offset, contentHeight: position.content, viewportHeight: position.viewport)
        }
        if wasFollowing, !state.followLive.isFollowing, state.retainedFirstID == nil {
            state.retainedFirstID = shown.first?.id
        }
    }

    private func scheduleReadingUpdate() {
        position.pagingTask?.cancel()
        position.pagingTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            if restoring { restoreAnchor() }
            observePosition()
            guard positioned, !restoring, !followingLayout else { return }
            if !shown.isEmpty {
                guard let anchor = ParallelVerticalAnchor.capture(ids: shown.map(\.id), frames: currentWidthFrames,
                    viewportHeight: position.viewport, offset: position.offset) else { return }
                if pendingReadingCapture || state.followLive.isFollowing || state.anchor == nil {
                    state.anchor = anchor
                    pendingReadingCapture = false
                }
            }
            maybeLoadOlder()
        }
    }

    private func finishRestoration() {
        defer {
            state.viewportPositioned = positioned && !restoring && !followingLayout
        }
        if !state.followLive.isFollowing { followingLayout = false }
        if state.followLive.isFollowing, followingLayout {
            if !positioned, let last = shown.last, position.frames[last.id] == nil { return }
            targetOffset = max(0, position.content - position.viewport)
            if abs(position.offset - (targetOffset ?? 0)) < 1 {
                followingLayout = false
                positioned = true
                restoring = false
            } else { return }
        }
        if restoring {
            if state.followLive.isFollowing,
               abs(position.offset - max(0, position.content - position.viewport)) < 2 {
                positioned = true; restoring = false
            } else if let targetOffset,
                      abs(position.offset - min(max(0, targetOffset), max(0, position.content - position.viewport))) < 1 {
                positioned = true; restoring = false
                restorationRowWidth = nil
            }
        }
    }

    private func beginRestoration() {
        restorationTiming = MonitorMetrics.begin()
        state.followLive.suspend()
        pendingReadingCapture = false
        position.pagingTask?.cancel()
        measurementGeneration &+= 1
        position.frames.removeAll(keepingCapacity: true)
        position.measurements.invalidateMeasurements()
        restoring = true
        state.viewportPositioned = false
        targetOffset = nil
    }

    private func restoreAnchor() {
        guard !state.followLive.isFollowing else { return }
        if shown.isEmpty {
            state.anchor = nil
            state.retainedFirstID = nil
            position.frames.removeAll()
            restorationRowWidth = nil
            targetOffset = 0
        } else if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)), let frame = position.frames[id] {
            if let restorationRowWidth, abs(frame.width - restorationRowWidth) > 1 { return }
            targetOffset = anchor.offset(in: frame)
        } else if state.anchor == nil { targetOffset = state.scrollOffset }
        finishRestoration()
    }

    private var upwardIntent: (() -> Void)? {
        isVisible ? { replenishShortFill() } : nil
    }

    private func replenishShortFill() {
        guard isVisible, positioned, !restoring, !waitingForPage, !history.isLoading else { return }
        shortFillBudget.replenish()
        rejectedPageIDs = nil
        if position.content <= position.viewport + 1 { scheduleReadingUpdate() }
    }

    private func maybeLoadOlder() {
        guard rejectedPageIDs != ids, !waitingForPage, ActivityFeedWindow.shouldLoad(offset: position.offset, viewport: position.viewport,
            eligibility: ActivityFeedEligibility(positioned: positioned, restoring: restoring, visible: isVisible,
                loading: history.isLoading, error: history.error)) else { return }
        let boundary = ActivityFeedWindow.olderBoundary(ids: ids, retainedID: state.retainedFirstID)
        guard boundary != nil || history.hasMore,
              shortFillBudget.consume(content: position.content, viewport: position.viewport) else { return }
        if let boundary {
            beginRestoration()
            state.retainedFirstID = boundary
        } else if history.hasMore { requestPage(retry: false) }
    }

    private func requestPage(retry: Bool) {
        let timing = MonitorMetrics.begin()
        defer { MonitorMetrics.end(timing, stage: .activityPaginationRequest) }
        guard isVisible, !waitingForPage, !history.isLoading, let onLoadMore,
              retry || history.error == nil else { return }
        if retry { rejectedPageIDs = nil }
        requestedIDs = ids
        waitingForPage = true
        sawLoading = false
        guard onLoadMore() else {
            rejectedPageIDs = ids
            waitingForPage = false
            requestedIDs = []
            return
        }
        beginRestoration()
    }

    private func preserveRegroupedAnchor(old: [ActivityRow], next: [ActivityRow]) {
        guard let anchor = state.anchor, !next.contains(where: { $0.id == anchor.id }),
              let oldRow = old.first(where: { $0.id == anchor.id }) else { return }
        let members: Set<String> = switch oldRow {
        case .single(let row): [row.id]
        case .toolGroup(let group): Set(group.members.map(\.id))
        }
        if let index = next.firstIndex(where: { row in
            switch row {
            case .single(let value): !members.isDisjoint(with: [value.id])
            case .toolGroup(let group): group.members.contains { members.contains($0.id) }
            }
        }) {
            let replacement = next[index].id
            state.anchor = ParallelVerticalAnchor(id: replacement, index: index, relativeOffset: anchor.relativeOffset)
            if state.retainedFirstID == anchor.id { state.retainedFirstID = replacement }
            if state.expandedGroups.remove(anchor.id) != nil { state.expandedGroups.insert(replacement) }
        }
    }
}
