import MonitorCore
import PbUI
import SwiftUI

// MARK: - SummaryEditedFilesHeading

/// The recorded file count with its original, fully visible provenance caveat beside it.
struct SummaryEditedFilesHeading: View {
    let count: Int
    static let caveat = "As reported by the agent's own edit tools — not a git diff; changes made by shell commands aren't listed."

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: PbRadius.Metrics.spacing12) {
                title.fixedSize()
                caption
            }
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                title
                caption
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text("Files edited · \(count)").font(.pb(.headline, weight: .semibold)).monospacedDigit()
    }

    private var caption: some View {
        Text(Self.caveat)
.font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - SummaryEditedFileRow

/// A nonactionable file row: decorative file icon alongside the retained status glyph and truthful accessibility label.
struct SummaryEditedFileRow: View {
    let row: SummaryFileRow

    var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            Image(systemName: "doc.text")
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
                .accessibilityHidden(true)
            statusBadge(row.status)
            Text(row.name).font(.pb(.secondary, weight: .medium, design: .monospaced)).lineLimit(1)
            if let folder = row.parentFolder {
                Text(folder).font(.pb(.secondary, design: .monospaced)).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: PbRadius.Metrics.zero)
            if row.status == .unconfirmed {
                Text("no result recorded").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        .help(row.fullPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func statusBadge(_ status: EditedFileStatus) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case .edited: ("✓", Color.doneGreen)
        case .failed: ("✗", Color.failedRed)
        case .unconfirmed: ("?", Color.secondaryText)
        }
        return Text(symbol).font(.pb(.caption, weight: .bold)).foregroundStyle(color).frame(width: PbRadius.Metrics.spacing12)
    }
}

// MARK: - SummaryEditedFilesCard

/// The production file list, also used by previews and tests: lazy shared rows with full-width hairlines.
struct SummaryEditedFilesCard: View {
    let rows: [SummaryFileRow]
    var hiddenCount = 0
    var loadedCount = 0
    var additionalFileCount = 0
    var onShowLoaded: (() -> Void)?
    var onLoadMore: (() -> Void)?

    var body: some View {
        GroupedActivityCard {
            LazyVStack(alignment: .leading, spacing: PbRadius.Metrics.zero) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ActivityCardDivider() }
                    ActivityCardRow { SummaryEditedFileRow(row: row) }
                }
                if hiddenCount > 0, let onShowLoaded {
                    if !rows.isEmpty { ActivityCardDivider() }
                    ActivityCardRow {
                        Button("Show loaded \(loadedCount)", action: onShowLoaded).monospacedDigit()
                    }
                }
                if additionalFileCount > 0, let onLoadMore {
                    if !rows.isEmpty || (hiddenCount > 0 && onShowLoaded != nil) { ActivityCardDivider() }
                    ActivityCardRow {
                        Button("Load more files (\(additionalFileCount) task file entries not shown)", action: onLoadMore)
                            .buttonStyle(.link)
                            .font(.pb(.secondary, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

#if DEBUG
private struct SummaryEditedFilesPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            SummaryEditedFilesHeading(count: 3)
            SummaryEditedFilesCard(rows: [EditedFileStatus.edited, .failed, .unconfirmed].enumerated().map { index, status in
                SummaryFileRow(EditedFile(path: "/repo/Sources/AuthenticationCoordinator\(index).swift", status: status))
            })
        }
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.windowBG)
    }
}

#Preview("Files, all statuses - light") {
    SummaryEditedFilesPreview().frame(width: PbRadius.Metrics.taskColumnMaxWidth).preferredColorScheme(.light)
}

#Preview("Files, all statuses - dark") {
    SummaryEditedFilesPreview().frame(width: PbRadius.Metrics.taskColumnMaxWidth).preferredColorScheme(.dark)
}

#Preview("Files, narrow - light") {
    SummaryEditedFilesPreview().frame(width: PbRadius.Metrics.activityPreviewWidth).preferredColorScheme(.light)
}

#Preview("Files, narrow - dark") {
    SummaryEditedFilesPreview().frame(width: PbRadius.Metrics.activityPreviewWidth).preferredColorScheme(.dark)
}

#Preview("Files, reveal and paging rows - light") {
    SummaryEditedFilesCard(rows: [SummaryFileRow(EditedFile(path: "/repo/A.swift", status: .edited))],
        hiddenCount: 3, loadedCount: 4, additionalFileCount: 2, onShowLoaded: {}, onLoadMore: {})
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
.preferredColorScheme(.light)
}

#Preview("Files, reveal and paging rows - dark") {
    SummaryEditedFilesCard(rows: [SummaryFileRow(EditedFile(path: "/repo/A.swift", status: .edited))],
        hiddenCount: 3, loadedCount: 4, additionalFileCount: 2, onShowLoaded: {}, onLoadMore: {})
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
.preferredColorScheme(.dark)
}
#endif
