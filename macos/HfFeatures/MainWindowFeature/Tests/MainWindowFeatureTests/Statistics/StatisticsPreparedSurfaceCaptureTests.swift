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

    @Test func givenStaleReadyOverview_whenMounted_thenReportedCostAppearsOnlyOutsideWorkflowDrilldown() async {
        // given
        let model = CaptureModel()
        model.presentation.refreshFailure = "Showing the last complete snapshot."
        model.presentation.reportedCost = .init(value: "$12.50", coverage: "Reported by 5 of 5 executions")
        let fixture = RedesignHost(StatisticsView(model), size: CGSize(width: 1000, height: 620), appearance: .light)
        defer { fixture.close() }

        // when
        await fixture.settle {
            fixture.element("Reported cost") != nil
                && fixture.element("$12.50") != nil
                && fixture.element("Reported by 5 of 5 executions") != nil
        }

        // then
        #expect(model.presentation.state == .ready)
        #expect(model.presentation.refreshFailure != nil)
        #expect(fixture.element("Reported cost") != nil)
        #expect(fixture.element("$12.50") != nil)
        #expect(fixture.element("Reported by 5 of 5 executions") != nil)

        model.presentation.nodes = .init(
            workflowID: "flow", title: "Build", subtitle: "Workflow node",
            wallTime: "Unavailable", executionTime: "10 min", usage: "Unavailable",
            rows: [], footer: "No executions"
        )
        await fixture.settle { fixture.element("Reported cost") == nil }
        #expect(fixture.element("Reported cost") == nil)
        #expect(fixture.element("Reported by 5 of 5 executions") == nil)
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
            return value
        }()

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
