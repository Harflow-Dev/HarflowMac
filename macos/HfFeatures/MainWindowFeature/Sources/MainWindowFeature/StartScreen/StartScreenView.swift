import HfCommon
import HfUI
import SwiftUI

// MARK: - StartScreenView

/// The ready runtime's unselected detail pane, matching HarflowDesign 62b9675.
struct StartScreenView<VM: StartScreenViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: VM
    @State private var pulse = false

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    actions
                    workflows
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 52))
                .padding(.bottom, 52)
            }
        }
        .background(Color.windowBG)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = MainWindowEmblem.image {
                Image(nsImage: image)
.resizable()
.frame(width: 40, height: 40)
                    .foregroundStyle(Color.primaryText)
.padding(.bottom, 6)
.accessibilityHidden(true)
            }
            Text(viewModel.presentation.greeting).font(.hf(.hero, weight: .semibold)).foregroundStyle(Color.primaryText)
            if viewModel.loading {
                Capsule()
.fill(Color.neutralFill)
.frame(width: 260, height: 12)
                    .opacity(pulse && !reduceMotion ? 0.45 : 1)
                    .frame(height: 16)
                    .onAppear { pulse = true }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
                    .accessibilityLabel("Loading status")
            } else if let status = viewModel.presentation.status {
                Text(status)
.font(.hf(.body))
.foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.newSession) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("New session")
                    Text("⌘N").font(.hf(.caption)).opacity(0.8).padding(.leading, 4).accessibilityHidden(true)
                }
            }
            .buttonStyle(MonitorButtonStyle(.primary))
            .accessibilityLabel("New session, Command N")
            if !viewModel.presentation.rows.isEmpty {
                Button(action: viewModel.newWorkflow) {
                    Label("New workflow", systemImage: "point.3.connected.trianglepath.dotted")
                }.buttonStyle(MonitorButtonStyle(.tinted))
            }
        }
    }

    private var workflows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.presentation.rows.isEmpty {
                Text("Run a workflow")
.font(.hf(.caption, weight: .semibold))
                    .foregroundStyle(Color.tertiaryText)
.padding(.horizontal, 4)
                workflowRows
            } else if viewModel.definitionsAvailable {
                emptyWorkflows
            } else if !viewModel.loading {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved workflows could not be loaded.").font(.hf(.body)).foregroundStyle(Color.secondaryText)
                    Button("Retry", action: viewModel.retry).buttonStyle(MonitorButtonStyle(.tinted))
                }
            }
        }
    }

    private var workflowRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.presentation.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().overlay(Color.hairline) }
                Button { viewModel.run(name: row.name) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(Color.secondaryText)
.frame(width: 28, height: 28)
                            .background(Color.neutralFill, in: RoundedRectangle(cornerRadius: 7))
                        Text(row.name)
.font(.hf(.headline, weight: .medium))
.lineLimit(1)
                            .foregroundStyle(Color.primaryText)
.frame(maxWidth: .infinity, alignment: .leading)
                        if let count = row.count {
                            Text(count).font(.hf(.secondary)).monospacedDigit().foregroundStyle(Color.tertiaryText)
                        }
                        Label("Run", systemImage: "play")
.font(.hf(.body, weight: .semibold))
                            .foregroundStyle(Color.accentLink)
.padding(.horizontal, 12)
.frame(height: 26)
                            .background(Color.runningBG, in: Capsule())
                    }
                    .padding(.horizontal, 14)
.padding(.vertical, 12)
.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
.accessibilityLabel("Run \(row.name)")
            }
            if viewModel.presentation.total > 3 {
                Divider().overlay(Color.hairline)
                Button("Show all \(viewModel.presentation.total) workflows", action: viewModel.showAll)
                    .font(.hf(.body))
.foregroundStyle(Color.accentLink)
                    .buttonStyle(.plain)
.frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder))
        .clipShape(RoundedRectangle(cornerRadius: HfRadius.card))
    }

    private var emptyWorkflows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workflows yet").font(.hf(.headline, weight: .semibold)).foregroundStyle(Color.primaryText)
            Text("A workflow is a saved graph of agents, such as plan, implement and review. Build one once and run it on any task.")
                .font(.hf(.body))
.foregroundStyle(Color.secondaryText)
.fixedSize(horizontal: false, vertical: true)
            Button(action: viewModel.newWorkflow) { Label("Create workflow", systemImage: "plus") }
                .buttonStyle(MonitorButtonStyle(.tinted))
.padding(.top, 6)
        }
        .padding(14)
.frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder))
    }
}

#if DEBUG
@Observable @MainActor
private final class StartScreenPreviewMock: StartScreenViewModel {
    var loading = false
    var definitionsAvailable = true
    var presentation = StartScreenPresentation(greeting: "Good afternoon", status: "1 task and 1 workflow running. 2 tasks finished today.", rows: [
        StartScreenRow(id: "session", name: "Session reliability", count: "12 runs"),
        StartScreenRow(id: "development", name: "Development workflow", count: "1 run")
    ], total: 2)
    func didAppear() {}
    func didDisappear() {}
    func newSession() {}
    func newWorkflow() {}
    func showAll() {}
    func run(name _: String) {}
    func retry() {}
}

#Preview("Populated") { StartScreenView(StartScreenPreviewMock()).frame(width: 720, height: 620) }
#Preview("No workflows") {
    let model = StartScreenPreviewMock()
    model.presentation.rows = []; model.presentation.total = 0
    return StartScreenView(model).frame(width: 720, height: 620)
}

#Preview("Loading") {
    let model = StartScreenPreviewMock(); model.loading = true
    return StartScreenView(model).frame(width: 720, height: 620)
}

#Preview("Unavailable") {
    let model = StartScreenPreviewMock(); model.presentation.status = nil
    return StartScreenView(model).frame(width: 720, height: 620)
}
#endif
