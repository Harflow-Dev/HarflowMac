import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskPaneEscapeHostedTests + repetition

extension TaskPaneEscapeHostedTests {

    // MARK: - Repetition

    /// Regression for an intermittent failure seen once on the local-monitor path at split width, where the second Escape
    /// after a reveal did not close the pane. Each iteration reports the state it ended in, so a failure carries the evidence.
    @Test func givenARevealAtSplitWidth_whenRepeatedManyTimes_thenEveryRunClosesOnTheSecondEscape() async throws {
        for iteration in 1 ... 8 {
            // given
            let store = seededStore(open: .closed, tab: .artifacts)
            let host = await mount(PaneMocks.continuity(notices: ["A notice."]), store: store, width: 1280)
            defer { host.close() }
            await activate(host)
            try press(host, "1 notice")
            await host.page.settle { host.focusedLabel?.hasPrefix("Notices") == true }

            // when
            host.sendEscape(via: .application)
            let landed = await focusLands(on: "1 notice", host)
            host.sendEscape(via: .application)
            await host.page.settle { !host.hasPane }

            // then
            let responder = String(describing: host.page.window.firstResponder.map { type(of: $0) })
            let focus = String(describing: host.focusedLabel)
            let state = "iteration \(iteration): key \(host.page.window.isKeyWindow), responder \(responder), focus \(focus), landed \(landed)"
            #expect(!host.hasPane, "\(state)")
            #expect(store.openChoice(for: Self.conversation) == .closed, "\(state)")
        }
    }
}
