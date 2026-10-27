import HfCommon
import HfUI
import SwiftUI

// MARK: - StatisticsViewModel

@MainActor
protocol StatisticsViewModel: ViewModel {
    var presentation: StatisticsPresentation { get }
    func didAppear()
    func didDisappear()
    func selectRange(_ value: StatisticsRange)
    func selectMeasure(_ value: StatisticsMeasure)
    func selectList(_ value: StatisticsList)
    func selectRepository(_ id: String?)
    func selectHarness(_ id: String?)
    func selectRequestedModel(_ id: String?)
    func toggleRow(_ id: String)
    func showNodes(for id: String)
    func showOverview()
    func retry()
}

// MARK: - StatisticsView

struct StatisticsView<VM: StatisticsViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State private var viewModel: VM

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color.windowBG)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Statistics").font(.hf(.title)).foregroundStyle(Color.primaryText)
            Text("Last \(viewModel.presentation.range.rawValue) days · Finished work")
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.presentation.state {
        case .loading:
            ProgressView("Preparing statistics…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .empty(message):
            preparedContent(emptyMessage: message)
        case let .unsupported(message):
            Text(message).foregroundStyle(Color.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .error(message):
            VStack(spacing: 12) {
                Text(message).foregroundStyle(Color.secondaryText)
                Button("Retry") { viewModel.retry() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            preparedContent()
        }
    }

    private func preparedContent(emptyMessage: String? = nil) -> some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                preparedSurface(emptyMessage: emptyMessage)
                    .frame(width: max(880, viewport.size.width))
            }
        }
    }

    /// The production content boundary; scrolling and view-model lifetime remain owned by the screen.
    func preparedSurface(emptyMessage: String? = nil) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            controls
            if let failure = viewModel.presentation.refreshFailure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    Button("Retry refresh") { viewModel.retry() }
                }.statisticsCard()
            }
            if let emptyMessage {
                Text(emptyMessage + " Choose another range or adjust the filters to look for retained finished work.")
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let nodes = viewModel.presentation.nodes {
                nodePage(nodes)
            } else {
                chart
                ranking
            }
            ForEach(Array(viewModel.presentation.coverage.enumerated()), id: \.offset) { _, line in
                Text(line).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(24)
        .frame(minWidth: 880, maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Range", selection: Binding(get: { viewModel.presentation.range }, set: { viewModel.selectRange($0) })) {
                ForEach(StatisticsRange.allCases, id: \.self) { Text("\($0.rawValue) days").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 215)
            .accessibilityLabel("Time range")
            filter(
                "Repository",
                selected: viewModel.presentation.repository,
                selectedLabel: viewModel.presentation.repositoryLabel,
                options: viewModel.presentation.repositoryOptions,
                action: viewModel.selectRepository
            )
            filter(
                "Harness",
                selected: viewModel.presentation.harness,
                selectedLabel: viewModel.presentation.harnessLabel,
                options: viewModel.presentation.harnessOptions,
                action: viewModel.selectHarness
            )
            filter(
                "Requested model",
                selected: viewModel.presentation.requestedModel,
                selectedLabel: viewModel.presentation.modelLabel,
                options: viewModel.presentation.modelOptions,
                action: viewModel.selectRequestedModel
            )
            Spacer(minLength: 8)
            Text("Measure").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            Picker("Measure", selection: Binding(get: { viewModel.presentation.measure }, set: { viewModel.selectMeasure($0) })) {
                ForEach(StatisticsMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityLabel("Measure")
        }
    }

    private func filter(
        _ title: String,
        selected: String?,
        selectedLabel: String?,
        options: [StatisticsOption],
        action: @escaping (String?) -> Void
    ) -> some View {
        let label = selectedLabel ?? options.first(where: { $0.id == selected })?.label ?? (selected == nil ? "All" : "Unavailable selection")
        return Menu {
            Button("All") { action(nil) }
            ForEach(options) { option in
                Button(option.label) { action(option.id) }.help(option.label)
            }
        } label: {
            Text("\(title): \(label)").lineLimit(1)
        }
        .help("\(title): \(label)")
        .accessibilityLabel("\(title): \(label)")
    }

    private var chart: some View {
        let chart = viewModel.presentation.chart
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chart.title).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    Text(chart.total).font(.hf(.title)).foregroundStyle(Color.primaryText)
                    Text(chart.caption).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                legend("Workflow runs", value: chart.workflowTotal, color: .accentColor)
                legend("Tasks", value: chart.taskTotal, color: .accentColor.opacity(0.5))
            }
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(chart.topAxis); Spacer(); Text(chart.middleAxis); Spacer(); Text(chart.bottomAxis)
                }
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
                .frame(width: 42, height: 180)
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: chart.gap) {
                        ForEach(chart.bars) { bar in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: geometry.size.height * max(
                                    0,
                                    min(1, bar.taskFraction)
                                ))
                                Rectangle().fill(Color.accentColor).frame(height: geometry.size.height * max(0, min(1, bar.workflowFraction)))
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(bar.accessibilityLabel)
                            .help(bar.accessibilityLabel)
                        }
                    }
                    .frame(height: geometry.size.height)
                    .background {
                        VStack(spacing: 0) {
                            Rectangle().fill(Color.cardBorder).frame(height: 1)
                            Spacer(minLength: 0)
                            Rectangle().fill(Color.cardBorder).frame(height: 1)
                            Spacer(minLength: 0)
                            Rectangle().fill(Color.cardBorder).frame(height: 1)
                        }.accessibilityHidden(true)
                    }
                }.frame(height: 180)
            }
            HStack(spacing: chart.gap) {
                ForEach(chart.bars) { bar in
                    Color.clear
                        .frame(height: 16)
                        .overlay {
                            Text(bar.label)
                                .font(.hf(.caption))
                                .foregroundStyle(Color.secondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity)
                }
            }.padding(.leading, 48)
            if let disclosure = chart.disclosure {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                    Text(disclosure).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }.statisticsCard()
    }

    private func legend(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(Color.secondaryText)
            Text(value).foregroundStyle(Color.primaryText)
        }.font(.hf(.caption))
    }

    private var ranking: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Ranking", selection: Binding(get: { viewModel.presentation.list }, set: { viewModel.selectList($0) })) {
                    ForEach(StatisticsList.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 245)
                .accessibilityLabel("Ranking category")
                Text(viewModel.presentation.listTitle).font(.hf(.body)).bold()
                Spacer(minLength: 0)
                metricHeaders(primary: viewModel.presentation.primaryColumn, secondary: viewModel.presentation.secondaryColumn)
            }
            if viewModel.presentation.rows.isEmpty {
                Text(
                    "No \(viewModel.presentation.list.rawValue.lowercased()) match these filters. Change the range or filters to find retained work."
                )
                .font(.hf(.body))
                .foregroundStyle(Color.secondaryText)
            }
            ForEach(viewModel.presentation.rows) { row in rankingRow(row, interactive: true) }
            Text(viewModel.presentation.listFooter).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }.statisticsCard()
    }

    private func metricHeaders(primary: String, secondary: String) -> some View {
        Group {
            Text(primary).frame(width: 90, alignment: .trailing)
            Text(secondary).frame(width: 90, alignment: .trailing)
        }
        .font(.hf(.caption))
        .foregroundStyle(Color.secondaryText)
    }

    private func rankingRow(_ row: StatisticsRow, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                if interactive {
                    Button { viewModel.toggleRow(row.id) } label: {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.isExpanded ? "Collapse" : "Expand") \(row.title)")
                    .frame(width: 10)
                }
                Text(row.rank.map(String.init) ?? "").foregroundStyle(Color.secondaryText).frame(width: 20, alignment: .trailing)
                rowGlyph(row).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.hf(.body)).foregroundStyle(Color.primaryText)
                    Text(row.subtitle).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                }.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                rankingTrack(row.fraction).frame(width: 200)
                if let share = row.share { Text(share).foregroundStyle(Color.secondaryText).frame(width: 70, alignment: .trailing) }
                Text(row.value).frame(width: 90, alignment: .trailing)
                Text(row.secondaryValue).foregroundStyle(Color.secondaryText).frame(width: 90, alignment: .trailing)
            }
            if row.isExpanded, interactive { expandedRows(row) }
            Divider()
        }
    }

    @ViewBuilder private func rowGlyph(_ row: StatisticsRow) -> some View {
        if row.harnessDot {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityHidden(true)
        } else if let glyph = row.glyph {
            Image(systemName: glyph).foregroundStyle(Color.secondaryText).accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 14, height: 14).accessibilityHidden(true)
        }
    }

    private func rankingTrack(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.cardBorder)
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func expandedRows(_ row: StatisticsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.childrenTitle).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            ForEach(row.children) { child in
                HStack(spacing: 8) {
                    if let glyph = child.statusGlyph {
                        Image(systemName: glyph)
                            .foregroundStyle(child.isFailure ? Color.failedRed : Color.secondaryText)
                            .accessibilityLabel(child.statusLabel ?? "Status")
                    }
                    VStack(alignment: .leading) {
                        Text(child.title)
                        Text(child.subtitle).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    rankingTrack(child.fraction).frame(width: 100)
                    Text(child.value).frame(width: 90, alignment: .trailing)
                    Text(child.secondaryValue).foregroundStyle(Color.secondaryText).frame(width: 90, alignment: .trailing)
                }.font(.hf(.caption))
            }
            Text(row.childrenFooter).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            if row.canShowNodes { Button("Node breakdown") { viewModel.showNodes(for: row.id) } }
        }
        .padding(.leading, 24)
        .padding(.vertical, 6)
    }

    private func nodePage(_ page: StatisticsNodePage) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            Button("Back to statistics", systemImage: "chevron.left") { viewModel.showOverview() }
            Text(page.title).font(.hf(.title))
            Text(page.subtitle).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            HStack(alignment: .top, spacing: 12) {
                summary("Runs", page.runs, note: page.runsBreakdown)
                summary("Elapsed run time", page.wallTime, note: "Wall clock, all runs")
                summary("Summed execution time", page.executionTime, note: "Independent node executions added together")
                summary("Usage", page.usage, note: "Known qualified token subtotal")
            }
            Text("Node times are summed execution time. Parallel nodes run at the same time, so their total can exceed elapsed run time.")
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(page.rankingTitle).font(.hf(.body)).bold()
                    Spacer(minLength: 0)
                    Text("Share").font(.hf(.caption)).foregroundStyle(Color.secondaryText).frame(width: 70, alignment: .trailing)
                    metricHeaders(primary: page.primaryColumn, secondary: page.secondaryColumn)
                }
                ForEach(page.rows) { row in rankingRow(row, interactive: false) }
                Text(page.footer).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }.statisticsCard()
        }
    }

    private func summary(_ title: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            Text(value).font(.hf(.body)).bold()
            Text(note).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statisticsCard()
    }

}

private extension View {
    func statisticsCard() -> some View {
        padding(16)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
    }
}
