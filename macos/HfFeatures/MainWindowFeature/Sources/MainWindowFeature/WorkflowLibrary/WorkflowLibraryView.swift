import HfCommon
import HfUI
import SwiftUI

// MARK: - WorkflowLibraryViewModel

@MainActor protocol WorkflowLibraryViewModel: ViewModel {
    var presentation: WorkflowLibraryPresentation { get }
    func didAppear()
    func didDisappear()
    func retry()
    func edit(_ row: WorkflowLibraryRow)
    func run(_ row: WorkflowLibraryRow)
    func create(generate: Bool)
}

// MARK: - WorkflowLibraryView

/// Approved v2 workflows/list, empty and loading (3101abe), new menu (b710856).
struct WorkflowLibraryView<VM: WorkflowLibraryViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State private var viewModel: VM

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Workflows").font(.hf(.title, weight: .semibold))
                    Spacer()
                    if viewModel.presentation.phase != .empty { newMenu }
                }
                content
            }
            .padding(.horizontal, 32)
.padding(.top, 24)
.padding(.bottom, 40)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.windowBG)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var newMenu: some View {
        Menu {
            Button("Blank workflow", systemImage: "plus") { viewModel.create(generate: false) }
            Button("Generate with agent…", systemImage: "sparkles") { viewModel.create(generate: true) }
        } label: { Label("New workflow", systemImage: "plus") }
        .accessibilityIdentifier("workflow-library-new")
    }

    @ViewBuilder private var content: some View {
        switch viewModel.presentation.phase {
        case .loading:
            VStack(spacing: 0) {
                ForEach(0 ..< 5) { _ in
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 8).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).frame(width: 150, height: 14)
                            RoundedRectangle(cornerRadius: 3).frame(maxWidth: 280).frame(height: 12)
                        }
                        Spacer()
                    }.padding(.vertical, 18)
                }
            }
            .foregroundStyle(Color.secondary.opacity(0.12))
            .accessibilityElement(children: .ignore)
.accessibilityLabel("Loading workflows")
        case .empty:
            VStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted").resizable().scaledToFit().frame(width: 28, height: 28).foregroundStyle(.secondary)
                Text("No workflows yet").font(.headline)
                Text("A workflow chains agents into steps you can run again. Build one on the canvas, or describe what you need and an agent drafts it.")
                    .foregroundStyle(.secondary)
.multilineTextAlignment(.center)
.frame(maxWidth: 440)
                HStack {
                    Button("New workflow", systemImage: "plus") { viewModel.create(generate: false) }.buttonStyle(.borderedProminent)
                    Button("Describe one to an agent") { viewModel.create(generate: true) }
                }.padding(.top, 12)
            }
.padding(.top, 120)
.frame(maxWidth: .infinity)
        case .loaded:
            VStack(spacing: 0) {
                ForEach(viewModel.presentation.rows) { row in
                    HStack(spacing: 16) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.secondary)
.frame(width: 32, height: 32)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.hf(.reading, weight: .medium)).lineLimit(1)
                            if let description = row.description {
                                Text(description).font(.hf(.secondary)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if let count = row.nodeCount {
                            Text("\(count) \(count == 1 ? "node" : "nodes")").font(.hf(.secondary)).foregroundStyle(.tertiary)
                        }
                        Button("Edit", systemImage: "pencil") { viewModel.edit(row) }
.buttonStyle(.plain)
                            .accessibilityLabel("Edit \(row.name)")
.fixedSize()
                        Button("Run", systemImage: "play") { viewModel.run(row) }
                            .accessibilityLabel("Run \(row.name)")
.fixedSize()
                    }
.padding(.horizontal, 8)
.padding(.vertical, 14)
                    Divider()
                }
            }
        case .failed:
            failureDetails
        }
        if viewModel.presentation.phase != .failed, viewModel.presentation.error != nil { failureDetails }
    }

    private var failureDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.presentation.error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("Refresh workflows") { viewModel.retry() }
        }
    }
}

#if DEBUG
#Preview { WorkflowLibraryView(WorkflowLibraryPreviewMock()) }

@Observable @MainActor private final class WorkflowLibraryPreviewMock: WorkflowLibraryViewModel {
    var presentation = WorkflowLibraryPresentation(phase: .empty)
    func didAppear() {}
    func didDisappear() {}
    func retry() {}
    func edit(_: WorkflowLibraryRow) {}
    func run(_: WorkflowLibraryRow) {}
    func create(generate _: Bool) {}
}
#endif
