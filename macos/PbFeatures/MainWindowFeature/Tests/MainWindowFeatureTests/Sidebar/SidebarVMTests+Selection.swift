import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - SidebarVMTests selection ordering

@MainActor
extension SidebarVMTests {
    @Test func givenAnOlderQueuedSelection_whenAnotherRowIsTapped_thenSelectionDoesNotRevert() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.selectionSubject.send(.task("previous"))

        // when
        sut.didSelect(.task("current"))
        #expect(sut.selection == .task("current"))
        var queueDrained = false
        DispatchQueue.main.async { queueDrained = true }
        await waitUntil { queueDrained }

        // then
        #expect(sut.selection == .task("current"))
    }

}
