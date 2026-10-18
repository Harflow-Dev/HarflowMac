import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbCommon
import PbUI
import Testing

@MainActor
struct SidebarWorkflowShortcutTests {
    @Test func givenWorkflowAndItsShortcut_whenEitherSelected_thenBothShareCanonicalDestinationWithoutDuplicateIdentity() {
        // given
        let row = TaskRowModel(id: "child", backend: "workflow", title: "Child", status: .running, repoName: "repo", ageText: "")
        let real = SidebarItem.workflow(row)
        let alias = SidebarItem.workflowShortcut(row, parentRunID: "parent")
        // when
        let selection = alias.destination
        // then
        #expect(selection == .workflowRun("child"))
        #expect(real.destination == selection)
        #expect(real.isSelected(selection))
        #expect(alias.isSelected(real.destination))
        #expect(real.id != alias.id)
    }
}
