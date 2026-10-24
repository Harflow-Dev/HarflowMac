#if DEBUG

import HfCommon
import SwiftUI

// MARK: - ConnectionStatusPreviewMock

@Observable
@MainActor
final class ConnectionStatusPreviewMock: ConnectionStatusViewModel {
    var isConnected = true
    var helpText = "Connected · harflow-ctl"

    func didAppear() {}
    func didDisappear() {}
}

#endif
