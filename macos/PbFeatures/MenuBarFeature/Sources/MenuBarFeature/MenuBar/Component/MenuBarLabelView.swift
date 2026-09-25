//
//  MenuBarLabelView.swift
//  MenuBarFeature
//
//  Ported from the app target's `MenuBarView.swift` (`MenuBarLabel`). The status item is always on
//  screen, so this is where the window opener is captured — independent of whether the popover
//  (`MenuBarView`) has ever been opened. It shares the same `MenuBarVM` instance as the popover
//  content (built once by `MenuBarCoordinator`), which is why `runningCount` stays accurate even
//  while the popover is closed — see `MenuBarVM`'s header comment on that judgement call.
//

import SwiftUI

struct MenuBarLabelView<VM: MenuBarViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.openWindow) private var openWindow
    
    // MARK: - State
    
    @State var viewModel: VM
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            if viewModel.runningCount > 0 { Text("\(viewModel.runningCount)") }
        }
        .onAppear {
            viewModel.didAppear()
            viewModel.didCaptureWindowOpener { openWindow(id: "main") }
        }
    }
}
