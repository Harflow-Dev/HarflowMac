import MonitorCore
@testable import PbUI
import SwiftUI
import Testing

/// Monitor piece 4 (collapsible task tree): `TaskRowModel`'s tree fields default to values that
/// keep MenuBar's plain row byte-identical, and the chevron's accessibility text is task-specific
/// and reflects the expanded state.
@Suite struct TaskRowModelTests {

    private func model(hasChildren: Bool = false, isExpanded: Bool = true, guides: [TreeGuide] = []) -> TaskRowModel {
        TaskRowModel(
            id: "t1", backend: "claude", title: "Fix the login bug", statusLabel: "Done", statusColor: .doneGreen, ageText: "3h",
            hasChildren: hasChildren, isExpanded: isExpanded, guides: guides
        )
    }

    @Test func givenNoTreeFieldsPassed_whenConstructed_thenDefaultsMatchMenuBarsPlainRow() {
        // given / when
        let row = TaskRowModel(id: "t1", backend: "claude", title: "Fix the login bug", statusLabel: "Done", statusColor: .doneGreen, ageText: "3h")

        // then — MenuBar never sets these, so a chevron/gutter must never render for it.
        #expect(row.hasChildren == false)
        #expect(row.isExpanded == true)
        #expect(row.guides.isEmpty)
    }

    @Test func givenAnExpandedRow_whenAskedForItsChevronAccessibility_thenItSaysCollapse() {
        // given
        let row = model(hasChildren: true, isExpanded: true)

        // when / then
        #expect(row.chevronAccessibilityLabel == "Collapse Fix the login bug")
        #expect(row.chevronAccessibilityValue == "Expanded")
    }

    @Test func givenACollapsedRow_whenAskedForItsChevronAccessibility_thenItSaysExpand() {
        // given
        let row = model(hasChildren: true, isExpanded: false)

        // when / then
        #expect(row.chevronAccessibilityLabel == "Expand Fix the login bug")
        #expect(row.chevronAccessibilityValue == "Collapsed")
    }

    @Test func givenAThreeLevelTreesGuides_whenStored_thenTheyRoundTripUnchanged() {
        // given / when
        let row = model(guides: [.continuation, .last])

        // then — the model is a plain data carrier; `TreeGutter` (untestable without an AppKit
        // host) is the only consumer that interprets these.
        #expect(row.guides == [.continuation, .last])
    }
}
