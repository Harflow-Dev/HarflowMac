import HfCommon
import SwiftUI

// MARK: - PendingLaunchesViewModel

@MainActor
protocol PendingLaunchesViewModel: ViewModel {
    var presentation: PendingLaunchesPresentation { get }
    func didAppear()
    func didDisappear()
    func didTapCheckAgain()
}

// MARK: - PendingLaunchesView

struct PendingLaunchesView<VM: PendingLaunchesViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State private var viewModel: VM

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        PendingLaunchesContent(presentation: viewModel.presentation, onCheckAgain: viewModel.didTapCheckAgain)
            .onAppear { viewModel.didAppear() }
            .onDisappear { viewModel.didDisappear() }
            .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
@Observable @MainActor
final class PendingLaunchesPreviewMock: PendingLaunchesViewModel {
    var presentation: PendingLaunchesPresentation
    init(presentation: PendingLaunchesPresentation = PendingLaunchesFixture.inventory) {
        self.presentation = presentation
    }

    func didAppear() {}
    func didDisappear() {}
    func didTapCheckAgain() {}
}

#Preview { PendingLaunchesView(PendingLaunchesPreviewMock()).frame(width: 850, height: 700) }
#endif
