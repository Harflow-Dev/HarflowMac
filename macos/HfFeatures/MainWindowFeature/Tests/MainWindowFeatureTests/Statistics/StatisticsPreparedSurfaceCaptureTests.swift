import AppKit
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct StatisticsPreparedSurfaceCaptureTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenProductionPreparedSurface_whenRenderedOffscreen_thenBodyPixelsAppear(scheme: ColorScheme) throws {
        let model = CaptureModel()
        let surface = StatisticsView(model)
.preparedSurface()
            .frame(width: 1180, height: 820, alignment: .topLeading)
            .background(Color.windowBG)
            .environment(\.colorScheme, scheme)
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: surface)
            renderer.scale = 1.5
            renderer.proposedSize = ProposedViewSize(width: 1180, height: 820)
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
            let name = scheme == .light ? "statistics-prepared-surface-light.png" : "statistics-prepared-surface-dark.png"
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
                bottomAxis: "0", bars: bars
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
