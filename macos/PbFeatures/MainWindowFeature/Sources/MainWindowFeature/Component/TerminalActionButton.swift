import PbUI
import SwiftUI

// MARK: - TerminalActionButton

/// An optional terminal handoff, visually distinct from the task's primary navigation action.
struct TerminalActionButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Label(title, systemImage: "terminal") }
            .buttonStyle(QuietButtonStyle(isFilled: false))
    }
}

#if DEBUG
#Preview {
    HStack {
        Button("Open task") {}.buttonStyle(.link)
        Spacer()
        TerminalActionButton("Take over") {}
    }.padding()
}
#endif
