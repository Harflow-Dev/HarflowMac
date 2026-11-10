import HfCommon
import SwiftUI

// MARK: - PendingLaunchesViewModel

@MainActor
protocol PendingLaunchesViewModel: ViewModel {
    var presentation: PendingLaunchesPresentation { get }
    /// The selected launch's detail; nil shows the inventory.
    var detail: PendingLaunchDetailPresentation? { get }
    /// The inventory row that takes keyboard focus after Back.
    var focusRowID: String? { get }
    func didAppear()
    func didDisappear()
    func didTapCheckAgain()
    func didSelectRow(_ id: String)
    func didTapBack()
    func didTapDetailCheckAgain()
    func didTapCheckTaskStatus()
}

// MARK: - PendingLaunchesView

struct PendingLaunchesView<VM: PendingLaunchesViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State private var viewModel: VM

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        PendingLaunchesContent(
            presentation: viewModel.presentation, detail: viewModel.detail, focusRowID: viewModel.focusRowID,
            actions: .init(
                checkAgain: viewModel.didTapCheckAgain, select: viewModel.didSelectRow, back: viewModel.didTapBack,
                detailCheckAgain: viewModel.didTapDetailCheckAgain, checkTaskStatus: viewModel.didTapCheckTaskStatus
            )
        )
            .onAppear { viewModel.didAppear() }
            .onDisappear { viewModel.didDisappear() }
            .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
@Observable @MainActor
final class PendingLaunchesPreviewMock: PendingLaunchesViewModel {
    var presentation: PendingLaunchesPresentation
    var detail: PendingLaunchDetailPresentation?
    var focusRowID: String?
    init(presentation: PendingLaunchesPresentation = PendingLaunchesFixture.inventory, detail: PendingLaunchDetailPresentation? = nil) {
        self.presentation = presentation
        self.detail = detail
    }

    func didAppear() {}
    func didDisappear() {}
    func didTapCheckAgain() {}
    func didSelectRow(_: String) {}
    func didTapBack() {}
    func didTapDetailCheckAgain() {}
    func didTapCheckTaskStatus() {}
}

#Preview { PendingLaunchesView(PendingLaunchesPreviewMock()).frame(width: 850, height: 700) }
#endif
