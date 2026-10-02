import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - WorkflowViewModel

@MainActor
protocol WorkflowViewModel: ViewModel {
    var workflows: [WorkflowRecord] { get }
    var runs: [WorkflowRunModel] { get }
    var definition: [String: JSONValue] { get set }
    var name: String { get set }
    var loadedName: String { get }
    var revision: Int { get }
    var selectedNodeID: String? { get set }
    var selectedEdgeID: String? { get set }
    var connectionSourceID: String? { get set }
    var selectedRun: WorkflowRunModel? { get }
    var selectedActivationID: String? { get }
    var isEditing: Bool { get }
    var isBusy: Bool { get }
    var errorText: String? { get }
    var validationMessage: String? { get }
    var repo: String { get set }
    var prompt: String { get set }
    var freedom: String { get set }
    var instructions: String { get set }
    var additionalAttempts: Int { get set }
    var launchAgent: [String: JSONValue] { get set }
    var overrideOrchestrator: Bool { get set }
    var generationAgent: [String: JSONValue] { get set }
    var generationFallbacks: [[String: JSONValue]] { get set }
    var modelChoices: [String: [ModelChoiceModel]] { get }
    var showsRunSheet: Bool { get set }
    var showsGenerateSheet: Bool { get set }
    var parallel: ParallelVM { get }
    var nodes: [WorkflowNodeModel] { get }
    var edges: [WorkflowEdgeModel] { get }
    var backendIDs: [String] { get }
    var selectedNode: WorkflowNodeModel? { get }
    var selectedEdge: WorkflowEdgeModel? { get }
    var canSave: Bool { get }
    var hasUnsavedChanges: Bool { get }
    func didAppear()
    func didDisappear()
    func selectWorkflow(_ workflow: WorkflowRecord)
    func selectRun(_ run: WorkflowRunModel)
    func newWorkflow()
    func openWorkflowEditor(_ name: String)
    func save()
    func duplicate()
    func deleteWorkflow()
    func chooseRepo()
    func prepareLaunch()
    func start()
    func generate()
    func control(_ command: String)
    func selectNode(_ id: String)
    func selectActivation(_ id: String?)
    func updateNode(_ id: String, key: String, value: JSONValue?)
    func updateEdge(_ id: String, key: String, value: JSONValue?)
    func moveNode(_ id: String, to point: CGPoint)
    func addNode(_ kind: String, at point: CGPoint?)
    func deleteSelected()
    func loadModels(_ backend: String)
    func nodeStatus(_ id: String) -> String
    func nodeAttempt(_ id: String) -> Int
}

// MARK: - WorkflowView

struct WorkflowView<VM: WorkflowViewModel>: View {
    @Environment(\.viewEvent) var viewEvent
    @State var viewModel: VM
    @AppStorage("workflowViewMode") private var viewMode = "Graph"

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = viewModel.errorText {
                Text(error)
.font(.pb(.secondary))
.foregroundStyle(Color.failedRed)
.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
.padding(12)
                Divider()
            }
            if viewModel.selectedRun != nil {
                runContent
            } else {
                editor
            }
        }
        .background(Color.windowBG)
        .sheet(isPresented: Binding(get: { viewModel.showsRunSheet }, set: { viewModel.showsRunSheet = $0 })) {
            WorkflowLaunchSheet(viewModel: viewModel, isGenerating: false)
        }
        .sheet(isPresented: Binding(get: { viewModel.showsGenerateSheet }, set: { viewModel.showsGenerateSheet = $0 })) {
            WorkflowLaunchSheet(viewModel: viewModel, isGenerating: true)
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
        .publishViewEvent(from: viewModel.parallel, to: viewEvent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if viewModel.selectedRun == nil, viewModel.isEditing, viewModel.loadedName.isEmpty {
                    TextField("Workflow name", text: $viewModel.name, prompt: Text("New workflow"))
                        .textFieldStyle(.roundedBorder)
                        .font(.pb(.headline, weight: .semibold))
                        .frame(minWidth: 160, idealWidth: 220, maxWidth: 300)
                        .accessibilityLabel("Workflow name")
                        .help("Enter a workflow name to save")
                } else {
                    Text(viewModel.selectedRun?.name ?? (viewModel.isEditing ? viewModel.name : "Workflows"))
                        .font(.pb(.headline, weight: .semibold))
                }
                Text(viewModel.selectedRun.map { $0.status.replacingOccurrences(of: "_", with: " ").capitalized }
                     ?? (viewModel.isEditing ? "Revision \(viewModel.revision) · Workflow editor" : "Build reusable agent workflows"))
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            Spacer()
            if viewModel.isBusy {
                ProgressView().controlSize(.small)
            }
            if let run = viewModel.selectedRun {
                Picker("View", selection: $viewMode) {
                    Text("Graph").tag("Graph")
                    Text("Parallel").tag("Parallel")
                }
.pickerStyle(.segmented)
.frame(width: 170)
                if ["running", "starting"].contains(run.status) {
                    Button("Pause") { viewModel.control("pause") }.buttonStyle(QuietButtonStyle())
                }
                if !["completed", "failed", "cancelled"].contains(run.status) {
                    Button("Cancel", role: .destructive) { viewModel.control("cancel") }.buttonStyle(QuietButtonStyle())
                }
            } else if viewModel.isEditing {
                Menu {
                    Button("Generate with agent…") { viewModel.showsGenerateSheet = true }
                    Button("Duplicate") { viewModel.duplicate() }
                    Button("Delete", role: .destructive) { viewModel.deleteWorkflow() }.disabled(viewModel.loadedName.isEmpty)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                Button("Save") { viewModel.save() }.buttonStyle(QuietButtonStyle()).disabled(!viewModel.canSave)
                Button("Run", systemImage: "play") {
                    viewModel.prepareLaunch()
                }
.buttonStyle(QuietButtonStyle())
                    .disabled(viewModel.hasUnsavedChanges || viewModel.isBusy)
            } else {
                Button("Generate", systemImage: "sparkles") { viewModel.showsGenerateSheet = true }.buttonStyle(QuietButtonStyle())
                Button("New workflow", systemImage: "plus") { viewModel.newWorkflow() }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, 16)
.padding(.vertical, 12)
    }

    private var editor: some View {
        HSplitView {
            VStack(spacing: 0) {
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                stepTray
            }
            .frame(minWidth: 400)
            WorkflowInspector(viewModel: viewModel).frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
        }
    }

    private var stepTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Steps")
                    ForEach(WorkflowRole.palette, id: \.self) { role in
                        if ["start", "end"].contains(role), viewModel.nodes.contains(where: { $0.type == role }) {
                            stepChip(role).opacity(0.4).help("\(WorkflowRole.title(role)) is already on the canvas")
                        } else {
                            stepChip(role).help("Drag \(WorkflowRole.title(role)) onto the canvas").draggable(role)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 12) {
                Text(viewModel.validationMessage ?? "Drag steps onto the canvas; connect their dots.")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help(viewModel.validationMessage ?? "Drag an output dot to an input, or click the output then the destination. "
                          + "Select a step and press Delete to remove it.")
                Spacer(minLength: 0)
                if viewModel.connectionSourceID != nil {
                    Button("Cancel connection") { viewModel.connectionSourceID = nil }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(12)
        .background(Color.windowBG)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow steps")
    }

    private func stepChip(_ role: String) -> some View {
        Label(WorkflowRole.title(role), systemImage: WorkflowRole.symbol(role))
            .font(.pb(.secondary))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
    }

    private var canvas: some View {
        WorkflowCanvas(
            nodes: viewModel.nodes,
            edges: viewModel.edges,
            selectedNodeID: viewModel.selectedNodeID,
            selectedEdgeID: viewModel.selectedEdgeID,
            isEditable: viewModel.selectedRun == nil,
            takenEdgeIDs: Set(WorkflowJSON.objects(viewModel.selectedRun?.raw["decisions"]).flatMap {
                           $0["connections"]?.arrayValue?.compactMap(\.stringValue) ?? []
                       }),
            status: viewModel.nodeStatus,
            attempt: viewModel.nodeAttempt,
            onSelectNode: viewModel.selectNode,
            onSelectEdge: { viewModel.selectedEdgeID = $0; viewModel.selectedNodeID = nil },
            onMove: viewModel.moveNode,
            onConnect: { viewModel.connectionSourceID = $0 },
            onDrop: { viewModel.addNode($0, at: $1) },
            onDelete: viewModel.deleteSelected,
            onRename: { viewModel.updateNode($0, key: "title", value: .string($1)) }
        )
    }

    private var runContent: some View {
        VStack(spacing: 0) {
            WorkflowRunStatus(viewModel: viewModel)
            Divider()
            if viewMode == "Graph" {
                VSplitView {
                    HSplitView {
                        canvas
                        if viewModel.selectedNode != nil || viewModel.selectedEdge != nil {
                            WorkflowInspector(viewModel: viewModel).frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                        }
                    }.frame(minHeight: 170, idealHeight: 300)
                    activity.frame(minHeight: 240)
                }
            } else {
                activity
            }
        }
    }

    private var activity: some View {
        WorkflowActivityColumns(columns: viewModel.parallel.columns, selectedTaskID: selectedTaskID)
    }

    private var selectedTaskID: String? {
        guard let nodeID = viewModel.selectedNodeID else {
            return nil
        }
        return viewModel.selectedRun?
.activations
.last { $0["node_id"]?.stringValue == nodeID && $0["role"]?.stringValue == "node" }?["tasks"]?
.arrayValue?
            .last?["task_id"]?
.stringValue
    }
}

// MARK: - WorkflowActivityColumns

/// Reuses the actual Parallel renderer and models; workflow task associations only choose members.
struct WorkflowActivityColumns: View {
    let columns: [ParallelColumnModel]
    let selectedTaskID: String?

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    if columns.isEmpty {
                        Text("Agent activity appears here when a step starts.")
.font(.pb(.body))
.foregroundStyle(Color.secondaryText)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(columns) { column in
                                ParallelColumnView(model: column)
                                    .frame(width: ParallelLayout.columnWidth(memberCount: columns.count, availableWidth: proxy.size.width))
                                    .id(column.task.taskID)
                                Divider()
                            }
                        }
                    }
                }
                .onChange(of: selectedTaskID) { _, id in if let id {
                    scroll.scrollTo(id, anchor: .leading)
                } }
            }
        }
    }
}

#if DEBUG
#Preview("Workflow activity uses Parallel") {
    WorkflowActivityColumns(columns: ParallelViewModelMock().columns, selectedTaskID: nil).frame(width: 1000, height: 500)
}
#endif
