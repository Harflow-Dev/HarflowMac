import HfUI
import SwiftUI

// MARK: - ConnectionStatusView

struct ConnectionStatusView<VM: ConnectionStatusViewModel>: View {
    @State var viewModel: VM

    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Circle()
            .fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed)
            .frame(width: HfRadius.Metrics.sidebarConnectionDotSize, height: HfRadius.Metrics.sidebarConnectionDotSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.isConnected ? "Connected" : "Disconnected")
            .accessibilityHint(viewModel.helpText)
            .help(viewModel.helpText)
            .onAppear { viewModel.didAppear() }
            .onDisappear { viewModel.didDisappear() }
    }
}

#if DEBUG
#Preview {
    ConnectionStatusView(ConnectionStatusPreviewMock())
        .padding(HfRadius.Metrics.spacing12)
}
#endif
