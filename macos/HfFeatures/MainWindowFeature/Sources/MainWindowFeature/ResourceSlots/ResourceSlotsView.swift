import HfCommon
import HfUI
import SwiftUI

// MARK: - ResourceSlotsViewModel

@MainActor
protocol ResourceSlotsViewModel: ViewModel {
    var presentation: ResourceSlotsPresentation { get }
    var expandedResourceIDs: Set<String> { get }
    var expandedBlockerIDs: Set<String> { get }
    var readingState: ResourceSlotsReadingState { get }
    func didAppear()
    func didDisappear()
    func didTapRefresh()
    func didToggleResource(_ id: String)
    func didToggleBlockers(_ id: String)
    func didOpenOwner(_ rowID: String)
}

// MARK: - ResourceSlotsView

struct ResourceSlotsView<VM: ResourceSlotsViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State private var viewModel: VM

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        ResourceSlotsContent(presentation: viewModel.presentation, readingState: viewModel.readingState,
                             expandedResourceIDs: viewModel.expandedResourceIDs,
                             expandedBlockerIDs: viewModel.expandedBlockerIDs,
                             onToggleResource: viewModel.didToggleResource,
                             onToggleBlockers: viewModel.didToggleBlockers,
                             onOpenOwner: viewModel.didOpenOwner)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh resource slots", systemImage: "arrow.clockwise", action: viewModel.didTapRefresh)
                        .help("Read the current resource inventory and phase status")
                }
            }
            .onAppear { viewModel.didAppear() }
            .onDisappear { viewModel.didDisappear() }
            .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
@Observable @MainActor
private final class ResourceSlotsPreviewMock: ResourceSlotsViewModel {
    var presentation = ResourceSlotsPresentation(
        state: .empty(title: "No resource slots", message: "No configured names or active reservations were reported."), qualifiers: []
    )
    var expandedResourceIDs: Set<String> = []
    var expandedBlockerIDs: Set<String> = []
    let readingState = ResourceSlotsReadingState()
    func didAppear() {}
    func didDisappear() {}
    func didTapRefresh() {}
    func didToggleResource(_: String) {}
    func didToggleBlockers(_: String) {}
    func didOpenOwner(_: String) {}
}

#Preview { ResourceSlotsView(ResourceSlotsPreviewMock()).frame(width: 850, height: 700) }
#endif
