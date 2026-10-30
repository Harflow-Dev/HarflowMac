import HfUI
import SwiftUI

// MARK: - NeedsYouListView

struct NeedsYouListView<VM: NeedsYouViewModel>: View {
    let viewModel: VM
    let reduceMotion: Bool
    @State private var expanded: Set<String> = []

    private var presentation: NeedsYouPresentation { viewModel.presentation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                header
                notices
                content
            }
            .padding(HfRadius.Metrics.spacing16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
            Text("Needs you").font(.hf(.title)).foregroundStyle(Color.primaryText).accessibilityAddTraits(.isHeader)
            Text(presentation.summary).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private var notices: some View {
        if let notice = presentation.notice {
            HStack {
                Text(notice).font(.hf(.secondary))
                Spacer(minLength: 0)
                Button("Dismiss") { viewModel.didDismissNotice() }.buttonStyle(.link)
            }
            .padding(HfRadius.Metrics.spacing10)
            .background(Color.neutralFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
            .accessibilityElement(children: .combine)
        }
        if let partial = presentation.partialNotice {
            HStack {
                Text(partial).font(.hf(.secondary))
                Spacer(minLength: 0)
                Button("Try again") { viewModel.didTapRetry() }.buttonStyle(.link)
            }
            .padding(HfRadius.Metrics.spacing10)
            .background(Color.warningBG, in: RoundedRectangle(cornerRadius: HfRadius.row))
        }
        if let checking = presentation.checkingNote {
            Text(checking).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
        if let older = presentation.olderEngineNote {
            Text(older).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private var content: some View {
        if presentation.isLoading {
            ProgressView("Checking tasks and workflow runs…")
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityLabel("Loading requests")
        } else if presentation.rows.isEmpty {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
                Text("Nothing needs you").font(.hf(.headline))
                Text("Approvals, questions and recovery checkpoints you can answer appear here, whoever started the run.")
                    .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            .padding(.top, HfRadius.Metrics.spacing12)
        } else {
            VStack(spacing: HfRadius.Metrics.spacing10) {
                ForEach(presentation.rows) { row in
                    NeedsYouRowView(row: row, isExpanded: expanded.contains(row.id), open: { viewModel.didSelect(row.id) },
                                    toggle: { toggle(row.id) })
                        .opacity(row.isLeaving ? 0 : 1)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(reduceMotion ? nil : HfMotion.arrival, value: presentation.rows)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pending requests")
        }
    }

    private func toggle(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
    }
}

// MARK: - NeedsYouRowView

struct NeedsYouRowView: View {
    let row: NeedsYouRow
    let isExpanded: Bool
    let open: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HfRadius.Metrics.spacing12) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    NeedsYouKindChip(label: row.kindLabel)
                    Button(action: open) { Text(row.title).font(.hf(.headline)) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens this request")
                }
                NeedsYouPath(titles: row.pathTitles)
                Text(row.text)
                    .font(.hf(.body))
                    .lineLimit(row.isLong && !isExpanded ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if row.isLong {
                    Button(isExpanded ? "Show less" : "Show more", action: toggle).buttonStyle(.link).font(.hf(.caption))
                }
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    Text("Started by \(row.startedBy)")
                    if row.callerEnded { Text("Caller Ended") }
                    NeedsYouAgeText(since: row.waitingSince)
                }
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 0)
            Button("Answer", action: open).accessibilityLabel("Answer \(row.title)")
        }
        .padding(HfRadius.Metrics.spacing12)
        .background(Color.warningBG.opacity(0.5), in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.warningFG.opacity(0.6)))
    }
}
