import AppKit
import Foundation
@testable import MainWindowFeature

// MARK: - SidebarHistoryPresentationEvidence

/// Optional, bounded observations of raw geometry, including attempts suppressed by admission.
/// These facts never decide test readiness or change the pagination assertions.
@MainActor
final class SidebarHistoryPresentationEvidence {
    private var records: [[String: Any]] = []
    private var total = 0

    func record(rawVisible: Bool, coordinator: SidebarNativeList.Coordinator) {
        guard ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"]?.isEmpty == false,
              let outline = coordinator.outline, let scroll = coordinator.scroll else { return }
        var rows: [[String: Any]] = []
        for (index, box) in coordinator.boxes.enumerated() {
            guard let cell = coordinator.cells[box.entry.displayID], cell.association === box else { continue }
            var row: [String: Any] = [
                "id": box.entry.id, "association": box.associationToken.uuidString,
                "generation": box.reportGeneration, "attached": cell.window != nil,
                "animate": cell.animate, "settled": box.presentationSettled,
                "nativeHeight": outline.rect(ofRow: index).height
            ]
            row["committedHeight"] = box.height
            row["naturalHeight"] = box.naturalHeight
            row["latestHeight"] = box.latestHostedReport
            if let report = box.latestCombinedReport {
                row["progress"] = report.progress
                row["logicalTarget"] = report.logicalTarget
                row["reportedNaturalHeight"] = report.naturalHeight
                row["occupiedHeight"] = report.occupiedHeight
                row["reportAuthority"] = report.authorityGeneration
            }
            rows.append(row)
            if rows.count == 64 { break }
        }
        var record: [String: Any] = [
            "rawVisible": rawVisible, "unsettled": coordinator.hasUnsettledPresentations,
            "availableWidth": coordinator.availableWidth, "knownWidth": coordinator.knownWidth,
            "generation": coordinator.generation, "settledGeneration": coordinator.settledGeneration,
            "nativeOperationDepth": coordinator.nativeOperationDepth,
            "widthInvalidationQueued": coordinator.widthInvalidationQueued,
            "viewport": NSStringFromRect(outline.convert(scroll.contentView.bounds, from: scroll.contentView)),
            "rows": rows
        ]
        record["inputRevision"] = coordinator.input?.historyRevision
        record["appliedRevision"] = coordinator.appliedInput?.historyRevision
        total += 1
        records.append(record)
        if records.count > 160 { records.remove(at: 32) }
    }

    func write(name: String) {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let payload: [String: Any] = ["fixture": name, "total": total, "truncated": total > records.count, "attempts": records]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("sidebar-presentation-attempts-\(name).json"))
    }
}
