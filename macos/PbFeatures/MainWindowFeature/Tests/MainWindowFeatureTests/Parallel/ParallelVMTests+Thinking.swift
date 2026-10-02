import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenTerminalColumnWithoutOutput_whenColumnBuilds_thenNoThinkingIndicator() async {
        // given
        let harness = makeSUT()
        let completed = task(id: "settled", status: "completed")
        harness.tasksBox.value["settled"] = completed
        harness.sut.didAppear()
        // when
        harness.tasksSubject.send([completed])
        await waitUntil { harness.sut.columns.count == 1 }
        // then
        #expect(harness.sut.columns.first?.liveStep == nil)
    }

}
