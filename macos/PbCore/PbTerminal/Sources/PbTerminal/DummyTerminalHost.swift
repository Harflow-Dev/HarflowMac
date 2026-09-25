#if DEBUG
import SwiftUI

// MARK: - DummyTerminalHost

/// A stand-in for `TerminalHost` that never constructs or starts a `LocalProcessTerminalView` —
/// SwiftTerm spins up a real pty and a real child process, which previews (and most unit tests)
/// must never do. Use this wherever a preview or a `PreviewMock` VM needs *some* view in place of a
/// live terminal.
public struct DummyTerminalHost: View {
    let title: String

    public init(title: String = "terminal") {
        self.title = title
    }

    public var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(Text(title).foregroundStyle(.white).font(.system(size: 11, design: .monospaced)))
    }
}

#Preview {
    DummyTerminalHost(title: "claude · ~/Code/polybridge")
        .frame(width: 400, height: 200)
}
#endif
