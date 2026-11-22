import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct StatisticsPreparedSurfaceCaptureTests {
    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func givenReadyStatistics_whenViewportNarrowsAndWidens_thenDocumentTracksViewportWithoutHorizontalScroll(style: NSScroller.Style) async throws {
        // given
        _ = NSApplication.shared
        let model = CaptureModel()
        let host = NSHostingView(rootView: StatisticsView(model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 620)
        defer { window.contentView = nil; window.close() }

        // when
        try await assertViewport(style: style, width: 1000, host: host, window: window)
        try await assertViewport(style: style, width: 640, host: host, window: window)
        try await assertViewport(style: style, width: 760, host: host, window: window)
        try await assertViewport(style: style, width: 1000, host: host, window: window)
    }

    @Test func givenStaleReadyOverview_whenMounted_thenCardsAppearOnlyOutsideWorkflowDrilldown() async {
        // given
        let model = CaptureModel()
        model.presentation.refreshFailure = "Showing the last complete snapshot."
        let fixture = RedesignHost(StatisticsView(model), size: CGSize(width: 1000, height: 620), appearance: .light)
        defer { fixture.close() }
        let cards: [(title: String, parts: [String])] = [
            ("Tasks run", ["128", "Last 30 days"]),
            ("Success rate", ["94%", "7 failed · 2 cancelled", "As of latest finished execution"]),
            ("Reported cost", ["$12.50", "Reported by 5 of 5 executions"])
        ]
        let agentLine = "Agent-started tasks count as top-level tasks."
        func cardMatches() -> Bool {
            cards.allSatisfy { card in
                guard let value = fixture.cardValue(card.title) else { return false }
                return card.parts.allSatisfy { value.contains($0) }
            }
        }

        // when
        await fixture.settle { cardMatches() && fixture.hasText(agentLine) }

        // then
        #expect(model.presentation.state == .ready)
        #expect(model.presentation.refreshFailure != nil)
        for card in cards {
            let value = fixture.cardValue(card.title)
            #expect(value != nil, "No \(card.title) card")
            for part in card.parts { #expect(value?.contains(part) == true, "\(card.title) card lacks \(part): \(value ?? "-")") }
        }
        #expect(fixture.hasText(agentLine))

        model.presentation.nodes = .init(
            workflowID: "flow", title: "Build", subtitle: "Workflow node",
            wallTime: "Unavailable", executionTime: "10 min", usage: "Unavailable",
            rows: [], footer: "No executions"
        )
        await fixture.settle {
            !fixture.hasText("Reported cost") && !fixture.hasText("Tasks run") && !fixture.hasText("Success rate")
                && !fixture.hasText(agentLine)
        }
        for text in ["Tasks run", "Success rate", "Reported cost", agentLine] {
            #expect(!fixture.hasText(text), "\(text) must not show on the node page: \(fixture.describeText(text))")
        }
    }

    @Test func givenNoTaskSummary_whenMounted_thenOnlyReportedCostCardShows() async {
        // given
        let model = CaptureModel()
        model.presentation.taskSummary = nil
        let fixture = RedesignHost(StatisticsView(model), size: CGSize(width: 1000, height: 620), appearance: .light)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.hasText("Reported cost") }

        // then
        #expect(fixture.hasText("Reported cost"))
        #expect(!fixture.hasText("Tasks run"))
        #expect(!fixture.hasText("Success rate"))
    }

    private func assertViewport(style: NSScroller.Style, width: CGFloat, host: NSHostingView<StatisticsView<CaptureModel>>, window: NSWindow) async throws {
        window.setContentSize(CGSize(width: width, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 620)
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            guard let scroll = Self.descendants(of: host).compactMap({ $0 as? NSScrollView }).first else { return false }
            scroll.scrollerStyle = style
            scroll.hasVerticalScroller = true
            scroll.tile()
            guard let document = scroll.documentView else { return false }
            return abs(host.bounds.width - width) < 2 && scroll.contentView.bounds.width > 0
                && document.bounds.width <= scroll.contentView.bounds.width + 1
        }
        let scroll = try #require(Self.descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        // then
        #expect(scroll.hasHorizontalScroller == false)
        #expect(document.bounds.width <= scroll.contentView.bounds.width + 1,
                "Statistics document width must follow the current viewport after resizing to \(width) points")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test(arguments: [ColorScheme.light, .dark], [CGFloat(640), 1000, 1180])
    func givenProductionPreparedSurface_whenRenderedOffscreen_thenBodyPixelsAppear(scheme: ColorScheme, width: CGFloat) throws {
        let model = CaptureModel()
        let surface = StatisticsView(model)
.preparedSurface()
            .frame(width: width, height: 820, alignment: .topLeading)
            .background(Color.windowBG)
            .environment(\.colorScheme, scheme)
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: surface)
            renderer.scale = 1.5
            renderer.proposedSize = ProposedViewSize(width: width, height: 820)
            image = renderer.cgImage
        }
        let captured = try #require(image)
        let bitmap = NSBitmapImageRep(cgImage: captured)
        let bodyHasPaint = (0 ..< bitmap.pixelsHigh).contains { y in
            (0 ..< bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent < 0.8 || color.greenComponent < 0.8 || color.blueComponent < 0.8
            }
        }
        #expect(bodyHasPaint, "The production prepared surface must paint content pixels")
        if let path = ProcessInfo.processInfo.environment["HARFLOW_STATISTICS_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let appearanceName = scheme == .light ? "light" : "dark"
            let name = "statistics-prepared-surface-\(appearanceName)-\(Int(width)).png"
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
        }
    }

    @Observable @MainActor final class CaptureModel: StatisticsViewModel {
        var presentation: StatisticsPresentation = {
            var value = StatisticsPresentation()
            value.state = .ready
            var bars: [StatisticsBar] = []
            for index in 0 ..< 30 {
                let label = index.isMultiple(of: 7) ? "Oct \(index + 1)" : ""
                let workflowFraction = Double(index % 8 + 1) / 12
                let taskFraction = Double(index % 3) / 20
                bars.append(.init(
                    id: String(index), label: label, accessibilityLabel: "Oct \(index + 1)",
                    workflowFraction: workflowFraction, taskFraction: taskFraction
                ))
            }
            value.chart = StatisticsChart(
                title: "Total time", total: "85 h 32 min", caption: "Workflow wall time + standalone execution time",
                workflowTotal: "74 h 12 min", taskTotal: "11 h 20 min", topAxis: "10 h", middleAxis: "5 h",
                bottomAxis: "0", bars: bars, gap: 4
            )
            let run = StatisticsChildRow(
                id: "run", title: "Oct 25, 10:00", subtitle: "Done · 5 nodes", value: "42 min",
                secondaryValue: "20 k tokens", fraction: 1
            )
            value.rows = [StatisticsRow(
                id: "workflow", title: "Implement and review", subtitle: "96 runs · 24 min avg", value: "38 h 12 min",
                secondaryValue: "2.6 M tokens", fraction: 1, isExpanded: true, children: [run],
                childrenTitle: "Workflow runs, longest first", childrenFooter: "Showing 1 of 96 runs",
                canShowNodes: true, rank: 1, glyph: "point.3.connected.trianglepath.dotted", share: "100%", kindLabel: "Workflow"
            )]
            value.coverage = ["Retained history only · Usage coverage varies by harness"]
            value.taskSummary = CaptureModel.populatedSummary
            value.reportedCost = .init(value: "$12.50", coverage: "Reported by 5 of 5 executions")
            return value
        }()

        static let populatedSummary = StatisticsTaskSummary(
            tasksRun: "128", tasksDetail: "Last 30 days", successRate: "94%",
            successDetail: "7 failed · 2 cancelled", successCaption: "As of latest finished execution",
            coverage: [
                "Agent-started tasks count as top-level tasks.",
                "Counts tasks with a finished execution and an identifiable first run in this period. "
                    + "Tasks still running without a finished execution aren't shown.",
                "12 later executions aren't counted because their first run couldn't be identified in the available history."
            ]
        )

        static let unavailableSummary = StatisticsTaskSummary(
            tasksRun: "0", tasksDetail: "Last 30 days", successRate: "Unavailable",
            successDetail: "No eligible finished tasks", successCaption: "",
            coverage: [
                "Counts tasks with a finished execution and an identifiable first run in this period. "
                    + "Tasks still running without a finished execution aren't shown.",
                "3 execution records couldn't be read and aren't counted."
            ]
        )

        func didAppear() {}
        func didDisappear() {}
        func selectRange(_ value: StatisticsRange) { presentation.range = value }
        func selectMeasure(_ value: StatisticsMeasure) { presentation.measure = value }
        func selectList(_ value: StatisticsList) { presentation.list = value }
        func selectRepository(_ id: String?) { presentation.repository = id }
        func selectHarness(_ id: String?) { presentation.harness = id }
        func selectRequestedModel(_ id: String?) { presentation.requestedModel = id }
        func toggleRow(_ id: String) {}
        func showNodes(for id: String) {}
        func showOverview() {}
        func retry() {}
    }
}

extension ActivityFeedApprovalHostedTests {
    @Test func givenStatisticsOverview_whenHostedAtSupportedSizesAndStates_thenHeaderKeepsBothRangesWithoutOldFilters() async throws {
        let states: [(name: String, state: StatisticsScreenState)] = [
            ("ready", .ready), ("unsupported", .unsupported("statistics-page unavailable"))
        ]
        let sizes = [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)]
        let captureDirectory = HostedCaptureEvidence.directory("HARFLOW_STATISTICS_CAPTURE_DIR")

        for size in sizes {
            for (stateName, state) in states {
                let model = StatisticsPreparedSurfaceCaptureTests.CaptureModel()
                model.presentation.state = state
                let fixture = RedesignHost(StatisticsView(model), size: size, appearance: .light)
                defer { fixture.close() }

                await fixture.settle {
                    fixture.element("Statistics") != nil
                        && fixture.element("7 days") != nil
                        && fixture.element("30 days") != nil
                }

                let texts = fixture.descendants.flatMap { fixture.elements(in: $0) }.flatMap { element in
                    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                        fixture.string(element, $0)
                    }
                }
                #expect(fixture.element("Statistics") != nil)
                #expect(fixture.element("7 days") != nil)
                #expect(fixture.element("30 days") != nil)
                #expect(!texts.contains { $0.localizedCaseInsensitiveContains("90 days") })
                #expect(!texts.contains { value in
                    ["repository:", "harness:", "requested model:"].contains {
                        value.localizedCaseInsensitiveContains($0)
                    }
                })

                if stateName == "ready", size.width == 1280, let captureDirectory {
                    await HostedCaptureEvidence.prepare(fixture.window, dark: false)
                    await fixture.settle { fixture.hasStableRenderedFrame }
                    try await HostedCaptureEvidence.record(
                        directory: captureDirectory,
                        subject: .init(
                            suite: "StatisticsPreparedSurfaceCaptureTests", state: "overview-header",
                            dark: false, size: NSSize(width: size.width, height: size.height),
                            design: .init(
                                route: "statistics/overview", file: "v2/scripts/screens-statistics.js",
                                commit: "be78fa43eac717dc8054f644825ac1b256cd9cad"
                            )
                        ),
                        window: fixture.window, host: fixture.host
                    )
                }
            }
        }
    }
}

extension RedesignHost {
    /// The combined accessibility value of the card titled `title`, e.g. "Tasks run, 128, Last 30 days".
    func cardValue(_ title: String) -> String? {
        descendants.flatMap { elements(in: $0) }
            .compactMap { string($0, "accessibilityValue") }
            .first { $0.hasPrefix(title + ",") }
    }

    /// Debug description of every element mentioning `text`.
    func describeText(_ text: String) -> [String] {
        descendants.flatMap { elements(in: $0) }.compactMap { element in
            let parts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityRole"].map {
                "\($0.dropFirst(13))=\(string(element, $0) ?? "-")"
            }
            guard parts.contains(where: { $0.contains(text) }) else { return nil }
            return "\(type(of: element)) \(parts.joined(separator: "|")) frame=\(String(describing: frame(element)))"
        }
    }

    /// Whether any accessibility element's label, title or value contains `text`.
    func hasText(_ text: String) -> Bool {
        descendants.flatMap { elements(in: $0) }.contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                string(element, $0)?.contains(text) == true
            }
        }
    }
}

extension ActivityFeedApprovalHostedTests {
    @Test func givenStatisticsCards_whenHostedInBothAppearances_thenThreeCardsFitWithoutClipping() async throws {
        let summaries: [(name: String, summary: StatisticsTaskSummary)] = [
            ("populated", StatisticsPreparedSurfaceCaptureTests.CaptureModel.populatedSummary),
            ("unavailable", StatisticsPreparedSurfaceCaptureTests.CaptureModel.unavailableSummary)
        ]
        // Three across, then two plus one, then a single column (the card minimum is 180 points).
        let sizes: [(size: CGSize, layout: String)] = [
            (CGSize(width: 1000, height: 620), "row"), (CGSize(width: 1280, height: 800), "row"),
            (CGSize(width: 520, height: 800), "pair"), (CGSize(width: 400, height: 900), "column")
        ]
        let captureDirectory = HostedCaptureEvidence.directory("HARFLOW_STATISTICS_CAPTURE_DIR")

        for (size, layout) in sizes {
            for dark in [false, true] {
                for (name, summary) in summaries {
                    let model = StatisticsPreparedSurfaceCaptureTests.CaptureModel()
                    model.presentation.taskSummary = summary
                    let fixture = RedesignHost(StatisticsView(model), size: size, appearance: dark ? .dark : .light)
                    defer { fixture.close() }
                    await fixture.settle { fixture.hasText("Tasks run") && fixture.hasText("Success rate") && fixture.hasText("Reported cost") }

                    let frames = try StatisticsCardLayout.frames(in: fixture)
                    StatisticsCardLayout.assert(frames, layout: layout, size: size, content: fixture.window.contentLayoutRect)
                    #expect(fixture.hasText(summary.coverage[0]))

                    if let captureDirectory {
                        await HostedCaptureEvidence.prepare(fixture.window, dark: dark)
                        await fixture.settle { fixture.hasStableRenderedFrame }
                        try await HostedCaptureEvidence.record(
                            directory: captureDirectory,
                            subject: .init(
                                suite: "StatisticsPreparedSurfaceCaptureTests", state: "cards-" + name,
                                dark: dark, size: NSSize(width: size.width, height: size.height),
                                design: .init(
                                    route: "statistics/overview", file: "v2/scripts/screens-statistics.js",
                                    commit: "be78fa43eac717dc8054f644825ac1b256cd9cad"
                                )
                            ),
                            window: fixture.window, host: fixture.host
                        )
                    }
                }
            }
        }
    }
}

/// Frame lookup and layout expectations for the three Statistics cards.
@MainActor enum StatisticsCardLayout {
    static func frames(in fixture: RedesignHost) throws -> [CGRect] {
        try ["Tasks run", "Success rate", "Reported cost"].map { title in
            let matches = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
                fixture.string($0, "accessibilityValue")?.hasPrefix(title + ",") == true
            }
            return try #require(
                matches.compactMap { fixture.frame($0) }.first,
                "No \(title) card frame: \(fixture.describeText(title))"
            )
        }
    }

    static func assert(_ frames: [CGRect], layout: String, size: CGSize, content: CGRect) {
        for frame in frames {
            #expect(frame.minX >= content.minX - 0.5 && frame.maxX <= content.maxX + 0.5, "Card clipped horizontally at \(size)")
            #expect(frame.minY >= content.minY - 0.5 && frame.maxY <= content.maxY + 0.5, "Card clipped vertically at \(size)")
            #expect(frame.width >= 170 && frame.height >= 60)
        }
        func sameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool { abs(lhs.maxY - rhs.maxY) < 1 }
        func equalHeight(_ lhs: CGRect, _ rhs: CGRect) -> Bool { abs(lhs.height - rhs.height) < 1 }
        func above(_ upper: CGRect, _ lower: CGRect) -> Bool { upper.minY >= lower.maxY - 0.5 }
        switch layout {
        case "row":
            #expect(sameRow(frames[0], frames[1]) && sameRow(frames[1], frames[2]), "Three cards share one row at \(size)")
            #expect(frames[0].maxX <= frames[1].minX + 0.5 && frames[1].maxX <= frames[2].minX + 0.5)
            #expect(equalHeight(frames[0], frames[1]) && equalHeight(frames[1], frames[2]), "Row cards have equal heights at \(size)")
        case "pair":
            #expect(sameRow(frames[0], frames[1]) && frames[0].maxX <= frames[1].minX + 0.5, "Two cards share a row at \(size)")
            #expect(equalHeight(frames[0], frames[1]), "Paired cards have equal heights at \(size)")
            #expect(above(frames[0], frames[2]) && above(frames[1], frames[2]), "Cost card sits below the pair at \(size)")
        default:
            #expect(above(frames[0], frames[1]) && above(frames[1], frames[2]), "Cards stack in one column at \(size)")
        }
    }
}
