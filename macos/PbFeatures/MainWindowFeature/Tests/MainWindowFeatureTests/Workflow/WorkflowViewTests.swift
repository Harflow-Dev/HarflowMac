@testable import MainWindowFeature
import Testing

// MARK: - WorkflowViewTests

struct WorkflowViewTests {
    @Test func givenStepPalette_whenGroupedForTheTray_thenEveryRoleAppearsOnceWithOneDivider() {
        // given / when
        let items = WorkflowStepPalette.items()
        let roles = items.compactMap(\.role)
        // then — all eight drag-only roles, exactly once each, in the palette's own order
        // within each group.
        #expect(roles.count == 8)
        #expect(Set(roles) == Set(WorkflowRole.palette))
        #expect(items.filter { $0 == .divider }.count == 1)
        let agentRoles = WorkflowRole.palette.filter { !WorkflowStepPalette.structuralRoles.contains($0) }
        let structuralRoles = WorkflowRole.palette.filter { WorkflowStepPalette.structuralRoles.contains($0) }
        #expect(Array(items.prefix(agentRoles.count)).compactMap(\.role) == agentRoles)
        #expect(items.suffix(structuralRoles.count).compactMap(\.role) == structuralRoles)
    }

    @Test func givenStructuralRoles_whenGroupedForTheTray_thenDividerPrecedesThem() {
        // given / when
        let items = WorkflowStepPalette.items()
        // then — the divider is the boundary: no agent role after it, no structural role before.
        let dividerIndex = items.firstIndex(of: .divider)
        #expect(dividerIndex != nil)
        if let dividerIndex {
            #expect(items[..<dividerIndex].allSatisfy { WorkflowStepPalette.structuralRoles.isDisjoint(with: [$0.role].compactMap(\.self)) })
            #expect(items[(dividerIndex + 1)...].allSatisfy { WorkflowStepPalette.structuralRoles.contains($0.role ?? "") })
        }
    }
}
