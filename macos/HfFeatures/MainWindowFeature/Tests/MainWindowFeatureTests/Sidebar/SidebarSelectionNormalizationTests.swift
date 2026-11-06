import HfCommon
import HfUI
@testable import MainWindowFeature
import Testing

/// The single normalized selection key shared by native row selection, realized cell
/// configuration and measurement caching: every Needs you selection — with or without a request
/// id — resolves onto the one Needs you row, destinationless rows never highlight, and only a
/// matching task destination matches its selection. These are headless predicate tests against
/// the production coordinator; the hosted surface regression is
/// `SidebarUnifiedHostedTests.givenNeedsYouSelectionWithItemID_whenHosted_thenSingleNormalizedRowHighlights`.
@MainActor
@Suite(.serialized)
struct SidebarSelectionNormalizationTests {
    @Test func givenNoSelection_whenEntriesAreTested_thenNoRowMatches() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        coordinator.selection = nil
        let entries = Self.allFixtureEntries()
        // when
        let matched = entries.filter { coordinator.isSelected($0) }
        // then — a nil selection highlights nothing, not even destinationless rows.
        #expect(matched.isEmpty)
        #expect(coordinator.normalizedSelectionKey == nil)
    }

    @Test func givenEntriesWithoutDestinations_whenAnySelectionIsCurrent_thenHeadingsDiagnosticsAndSentinelNeverHighlight() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        let nonselectable = [
            Self.headingEntry(),
            Self.sentinelEntry(),
            Self.errorEntry()
        ]
        let selections: [MonitorDestination?] = [
            nil, .task("run-a"), .needsYou(itemID: nil), .needsYou(itemID: "stale-request")
        ]
        for selection in selections {
            // when
            coordinator.selection = selection
            // then — a missing destination never matches, not even against a missing selection.
            #expect(nonselectable.allSatisfy { !coordinator.isSelected($0) })
        }
    }

    @Test func givenNeedsYouSelectionWithoutRequestID_whenEntriesAreTested_thenEveryNeedsYouRealizationMatchesAlone() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        // when
        coordinator.selection = .needsYou(itemID: nil)
        // then
        #expect(coordinator.normalizedSelectionKey == .needsYou(itemID: nil))
        #expect(coordinator.isSelected(Self.needsYouNavigationEntry()))
        #expect(coordinator.isSelected(Self.needsYouContentEntry()))
        #expect(!coordinator.isSelected(Self.statisticsNavigationEntry()))
        #expect(!coordinator.isSelected(Self.taskEntry(id: "run-a")))
    }

    @Test func givenNeedsYouSelectionWithRequestID_whenEntriesAreTested_thenSingleNormalizedRowMatches() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        // when
        coordinator.selection = .needsYou(itemID: "stale-request")
        // then — the request id normalizes away for every native surface.
        #expect(coordinator.normalizedSelectionKey == .needsYou(itemID: nil))
        #expect(coordinator.isSelected(Self.needsYouNavigationEntry()))
        #expect(coordinator.isSelected(Self.needsYouContentEntry()))
        #expect(!coordinator.isSelected(Self.newTaskNavigationEntry()))
        #expect(!coordinator.isSelected(Self.statisticsNavigationEntry()))
        #expect(!coordinator.isSelected(Self.taskEntry(id: "run-a")))
    }

    @Test func givenTaskSelection_whenTasksAreTested_thenOnlyTheMatchingDestinationMatches() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        let running = Self.taskEntry(id: "run-a")
        let earlier = Self.taskEntry(id: "today-b")
        // when
        coordinator.selection = .task("run-a")
        // then
        #expect(coordinator.normalizedSelectionKey == .task("run-a"))
        #expect(coordinator.isSelected(running))
        #expect(!coordinator.isSelected(earlier))
        #expect(!coordinator.isSelected(Self.needsYouNavigationEntry()))
    }

    @Test func givenFadingTombstones_whenTheirDestinationWouldMatch_thenTheyStillNeverHighlight() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        var fadingNeedsYou = Self.needsYouNavigationEntry()
        fadingNeedsYou.isFading = true
        var fadingTask = Self.taskEntry(id: "run-a")
        fadingTask.isFading = true
        // when
        coordinator.selection = .needsYou(itemID: "stale-request")
        // then — a fading row loses its destination and its hosted highlight.
        #expect(!coordinator.isSelected(fadingNeedsYou))
        coordinator.selection = .task("run-a")
        #expect(!coordinator.isSelected(fadingTask))
    }

    @Test func givenMeasurementCacheKeys_whenSelectedIsDerivedFromTheSharedPredicate_thenNormalizationIsStableAndDistinguishesSelection() {
        // given
        let coordinator = SidebarNativeList.Coordinator()
        let entry = Self.needsYouNavigationEntry()
        func key(selected: Bool) -> SidebarNativeMeasurementKey {
            SidebarNativeMeasurementKey(entryRevision: 3, width: 300, environmentRevision: 1,
                                        selected: selected, emphasized: false)
        }

        // when — two Needs you request ids and an unselected state derive their cache key's
        // selected input through the same predicate realization and measurement share.
        coordinator.selection = .needsYou(itemID: "stale-request")
        let withRequestID = key(selected: coordinator.isSelected(entry))
        coordinator.selection = .needsYou(itemID: nil)
        let withoutRequestID = key(selected: coordinator.isSelected(entry))
        coordinator.selection = .task("run-a")
        let taskSelection = key(selected: coordinator.isSelected(entry))

        // then — request-id churn never re-measures, but a genuine selection flip invalidates.
        #expect(withRequestID == withoutRequestID)
        #expect(withRequestID != taskSelection)
        #expect(key(selected: true) != key(selected: false))
    }

    // MARK: - Fixtures

    private static func allFixtureEntries() -> [SidebarListEntry] {
        [
            headingEntry(),
            sentinelEntry(),
            errorEntry(),
            needsYouNavigationEntry(),
            needsYouContentEntry(),
            statisticsNavigationEntry(),
            newTaskNavigationEntry(),
            taskEntry(id: "run-a")
        ]
    }

    private static func navigationEntry(_ id: String) -> SidebarListEntry {
        let navigation = SidebarNavigationEntry.unifiedEntries(badge: .none).first { $0.id == id }!
        return SidebarListEntry(id: navigation.id, content: .navigation(navigation))
    }

    private static func needsYouNavigationEntry() -> SidebarListEntry { navigationEntry("navigation:needs-you") }
    private static func statisticsNavigationEntry() -> SidebarListEntry { navigationEntry("navigation:statistics") }
    private static func newTaskNavigationEntry() -> SidebarListEntry { navigationEntry("navigation:new-task") }

    private static func needsYouContentEntry() -> SidebarListEntry {
        SidebarListEntry(id: "needs-you", content: .needsYou(.count(2, atLeast: false)))
    }

    private static func headingEntry() -> SidebarListEntry {
        SidebarListEntry(id: "header:running", content: .heading("Running"))
    }

    private static func sentinelEntry() -> SidebarListEntry {
        SidebarListEntry(id: "history:sentinel", content: .sentinel)
    }

    private static func errorEntry() -> SidebarListEntry {
        SidebarListEntry(id: "diagnostic:read", content: .error("Listing failed"))
    }

    private static func taskEntry(id: String) -> SidebarListEntry {
        SidebarListEntry(id: "task:\(id)", content: .item(.task(TaskRowModel(
            id: id, backend: "codex", title: id, status: .completed,
            repoName: "repo", ageText: "1h", indent: 0
        ))))
    }
}
