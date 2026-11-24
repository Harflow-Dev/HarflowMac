//
//  HarnessesView.swift
//  SettingsFeature
//

import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - HarnessesViewModel

/// View model protocol for the Harnesses settings tab.
@MainActor
protocol HarnessesViewModel: ViewModel {
    var qualificationCards: [QualificationCard] { get }
    /// One-line rows for the harnesses that have no native qualification, after the cards.
    var qualificationNotes: [QualificationNote] { get }
    func didTapQualification(_ id: String)
    
    var rows: [HarnessRow] { get }
    var serverPath: String? { get }
    /// The status load's failure: the engine's sentence and, when the refusal has one, its code.
    var loadFailure: HarnessLoadFailure? { get }
    /// Failed actions by row key; a failed row shows the message, its code and Retry.
    var rowFailures: [String: HarnessRowFailure] { get }
    var isLoading: Bool { get }
    var workingKey: String? { get }
    var isRefreshDisabled: Bool { get }
    /// The runtime is not ready: the page shows a setup note instead of the list.
    var showsRuntimeSetup: Bool { get }
    /// The runtime is ready and the setup tool listed no harness.
    var showsNoHarnesses: Bool { get }

    func didAppear()
    func didDisappear()
    func didTapRefresh()
    func didTapInstall(_ row: HarnessRow)
    func didTapRemove(_ row: HarnessRow)
    func didTapRetry(_ row: HarnessRow)
    func didTapOpenSetup()
}

// MARK: - HarnessesView

/// Rows from `harflow-setup --status --json`. Install and Remove run `harflow-setup` only
/// when clicked, after a confirmation dialog.
struct HarnessesView<VM: HarnessesViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    @State private var expandedAllowlistKey: String?
    private let buildAllowlist: (HarnessRow) -> AnyView
    
    // MARK: - Init
    
    init(_ viewModel: VM, buildAllowlist: @escaping (HarnessRow) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.buildAllowlist = buildAllowlist
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            HStack {
                Text("Where Harflow is registered as an MCP server").font(.hf(.headline, weight: .semibold))
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { viewModel.didTapRefresh() }.disabled(viewModel.isRefreshDisabled)
            }
            if let serverPath = viewModel.serverPath {
                Text("Server: \(serverPath)")
                    .font(.hf(.secondary, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
            }
            if viewModel.showsRuntimeSetup {
                HarnessBlock {
                    Text("Finish runtime setup to register Harflow with your harnesses.")
                        .font(.hf(.body))
                        .foregroundStyle(Color.primaryText)
                    Button("Open setup") { viewModel.didTapOpenSetup() }
                }
                Spacer(minLength: 0)
            } else {
                registrationState
                List {
                    ForEach(viewModel.rows) { row in
                        HarnessRowView(
                            row: row,
                            isWorking: viewModel.workingKey == row.key,
                            isAnyWorking: viewModel.workingKey != nil,
                            onInstall: { viewModel.didTapInstall(row) },
                            onRemove: { viewModel.didTapRemove(row) },
                            onAllowlist: { expandedAllowlistKey = expandedAllowlistKey == row.key ? nil : row.key },
                            isAllowlistExpanded: expandedAllowlistKey == row.key,
                            failure: viewModel.rowFailures[row.key],
                            onRetry: { viewModel.didTapRetry(row) }
                        )
                        if expandedAllowlistKey == row.key {
                            InlineAllowlistPanel(row: row, build: buildAllowlist)
                        }
                    }
                    Section("Harness qualification") {
                        ForEach(viewModel.qualificationCards) { card in
                            QualificationCardRow(card: card) { viewModel.didTapQualification(card.id) }
                        }
                        ForEach(viewModel.qualificationNotes) { note in
                            QualificationNoteRow(note: note)
                        }
                    }
                }
                // Bounded scope (§6.7): the native List's own scroll view carries thin overlay
                // chrome, independent of row presence — empty and repopulated lists keep it.
                .scrollChromeScope()
            }
        }
        .padding(HfRadius.Metrics.spacing16)
        .onChange(of: viewModel.rows.map(\.key)) { _, keys in
            if let key = expandedAllowlistKey, !keys.contains(key) { expandedAllowlistKey = nil }
        }
        .onChange(of: viewModel.showsRuntimeSetup) { _, showing in
            if showing { expandedAllowlistKey = nil }
        }
        .onChange(of: Set(viewModel.rowFailures.keys)) { _, failed in
            if let key = expandedAllowlistKey, failed.contains(key) { expandedAllowlistKey = nil }
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

// MARK: - HarnessesView + Registration state

extension HarnessesView {
    /// The refused or empty block above the list; nothing while rows load or show.
    @ViewBuilder private var registrationState: some View {
        if let failure = viewModel.loadFailure {
            HarnessBlock {
                Text(failure.message)
                    .font(.hf(.body))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = failure.code { DetailLine(label: "Code", value: code) }
                Button("Retry") { viewModel.didTapRefresh() }.disabled(viewModel.isRefreshDisabled)
            }
        } else if viewModel.showsNoHarnesses {
            HarnessBlock {
                Text("No harnesses found on this Mac.")
                    .font(.hf(.body))
                    .foregroundStyle(Color.primaryText)
                Text("Install a supported harness, then refresh.")
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }
}

// MARK: - InlineAllowlistPanel

/// The panel under its harness row. It builds the panel once per appearance, so a change to the rows above never
/// replaces the panel's view model or the focus in its field.
private struct InlineAllowlistPanel: View {
    let row: HarnessRow
    let build: (HarnessRow) -> AnyView
    @State private var panel: AnyView?

    var body: some View {
        Group {
            if let panel {
                panel
            } else {
                Color.clear.frame(height: 0).onAppear { panel = build(row) }
            }
        }
        .padding(.leading, HfRadius.Metrics.spacing20)
    }
}

// MARK: - QualificationCardRow

/// A qualification card with its state glyph before it; Qualifying and Not checked draw none.
private struct QualificationCardRow: View {
    let card: QualificationCard
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
            if let glyph = QualificationGlyph.for(card.model.state) { RowGlyphView(glyph: glyph).accessibilityHidden(true) }
            HarnessQualificationCard(model: card.model, action: action)
        }
    }
}

// MARK: - QualificationNoteRow

/// A harness without a qualification card: its name and one line, with the not-found glyph when it is not installed.
private struct QualificationNoteRow: View {
    let note: QualificationNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HfRadius.Metrics.spacing16) {
            Text(note.identity).font(.hf(.body))
            Spacer(minLength: 0)
            HStack(spacing: HfRadius.Metrics.spacing4) {
                if let glyph = note.glyph { RowGlyphView(glyph: glyph).accessibilityHidden(true) }
                Text(note.text).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - HarnessBlock

/// The design's `hd-hs-block`: a short column between two hairlines that replaces the list in a state without rows.
private struct HarnessBlock<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HfRadius.Metrics.spacing16)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

#if DEBUG
#Preview("Harnesses - light") {
    HarnessesView(HarnessesViewModelMock()).preferredColorScheme(.light)
}

#Preview("Harnesses - dark") {
    HarnessesView(HarnessesViewModelMock()).preferredColorScheme(.dark)
}

#Preview("Harnesses, runtime not ready - light") {
    HarnessesView(HarnessesViewModelMock(showsRuntimeSetup: true)).preferredColorScheme(.light)
}

#Preview("Harnesses, runtime not ready - dark") {
    HarnessesView(HarnessesViewModelMock(showsRuntimeSetup: true)).preferredColorScheme(.dark)
}

#Preview("Harnesses, setup refused - light") {
    HarnessesView(HarnessesViewModelMock(
        rows: [], serverPath: nil,
        loadFailure: .init(message: "Incompatible Harflow runtime: unsupported harflow.setup format", code: "incompatible_runtime")
    )).preferredColorScheme(.light)
}

#Preview("Harnesses, setup refused - dark") {
    HarnessesView(HarnessesViewModelMock(
        rows: [], serverPath: nil,
        loadFailure: .init(message: "Incompatible Harflow runtime: unsupported harflow.setup format", code: "incompatible_runtime")
    )).preferredColorScheme(.dark)
}

#Preview("Harnesses, none found - light") {
    HarnessesView(HarnessesViewModelMock(rows: [], serverPath: nil, showsNoHarnesses: true)).preferredColorScheme(.light)
}

#Preview("Harnesses, none found - dark") {
    HarnessesView(HarnessesViewModelMock(rows: [], serverPath: nil, showsNoHarnesses: true)).preferredColorScheme(.dark)
}

#Preview("Harnesses, registration failed - light") {
    HarnessesView(HarnessesViewModelMock(rowFailures: HarnessesViewModelMock.sampleRowFailures)).preferredColorScheme(.light)
}

#Preview("Harnesses, registration failed - dark") {
    HarnessesView(HarnessesViewModelMock(rowFailures: HarnessesViewModelMock.sampleRowFailures)).preferredColorScheme(.dark)
}
#endif

extension HarnessesViewModel {
    var qualificationCards: [QualificationCard] { [] }
    var qualificationNotes: [QualificationNote] { [] }
    func didTapQualification(_: String) {}
}
