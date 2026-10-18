import AppKit
@testable import MainWindowFeature
@testable import MonitorCore
import PbCommon
import PbTestUtilities
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SidebarNativeHeaderAccessibilityTests {
    @Test func givenAWorkflowsHeader_whenAccessibilityButtonsArePressed_thenEachActionFiresOnce() async throws {
        // given — the production native cell and its real SwiftUI accessibility children.
        _ = NSApplication.shared
        let axAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApplication.shared.accessibilityAttributeValue(axAttribute)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: axAttribute)
        defer { NSApplication.shared.accessibilitySetValue(previousAX, forAttribute: axAttribute) }
        let actions = SidebarNativeActions()
        var collapseCount = 0
        var newWorkflowCount = 0
        actions.toggleWorkflows = { collapseCount += 1 }
        actions.newWorkflow = { newWorkflowCount += 1 }
        let cell = SidebarNativeCell(frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        cell.configure(
            entry: SidebarListEntry(id: "header:workflows", content: .workflowsHeader(expanded: true)),
            actions: actions, selected: false, animate: false, environment: EnvironmentValues(), onHeight: { _ in }
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cell
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            cell.layoutSubtreeIfNeeded()
            return accessibilityObjects(in: cell).contains { label(of: $0) == "New workflow" }
        }

        // when — invoke the public accessibility press action on each real child.
        let elements = unique(accessibilityObjects(in: cell))
        #expect(elements.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows" }.count == 1)
        #expect(elements.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "New workflow" }.count == 1)
        let collapse = try #require(elements.first { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows" })
        let newWorkflow = try #require(elements.first { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "New workflow" })
        #expect(press(collapse))
        #expect(collapseCount == 1)
        #expect(newWorkflowCount == 0)
        #expect(press(newWorkflow))

        // then — neither action routes through selection or fires more than once.
        #expect(collapseCount == 1)
        #expect(newWorkflowCount == 1)
    }

    // The integration assertion intentionally keeps the complete AX state transition together.
    // swiftlint:disable:next function_body_length
    @Test func givenTheRealSidebar_whenWorkflowHeaderAccessibilityActionsArePressed_thenOnlyTheirOwnStateChanges() async throws {
        // given — the real SidebarVM routing owner and a retained native window.
        _ = NSApplication.shared
        let axAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApplication.shared.accessibilityAttributeValue(axAttribute)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: axAttribute)
        defer { NSApplication.shared.accessibilitySetValue(previousAX, forAttribute: axAttribute) }
        var selections: [MonitorDestination?] = []
        let harness = SidebarVMTests().makeSUT(onSelect: { selections.append($0) })
        harness.sut.workflowDefinitions = [WorkflowRecord(raw: ["name": .string("baseline-definition")])]
        let host = NSHostingView(rootView: AnyView(SidebarView(harness.sut).frame(width: 320, height: 760)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        harness.sut.didAppear()
        harness.sut.recompute()
        defer {
            harness.sut.didDisappear()
            window.contentView = nil
            window.close()
        }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return unique(accessibilityObjects(in: host)).contains {
                role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows"
            }
        }
        let header = try #require(nativeViews(in: host).compactMap { $0 as? SidebarNativeCell }.first {
            $0.accessibilityRole() == .headingRole && $0.accessibilityLabel() == "Collapse workflows"
        })

        // when — press the actual public AX children, not the cell's heading element.
        let before = unique(accessibilityObjects(in: header))
        #expect(before.filter { role(of: $0) == NSAccessibility.Role.headingRole.rawValue && label(of: $0) == "Collapse workflows" }.count == 1)
        #expect(before.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows" }.count == 1)
        #expect(before.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "New workflow" }.count == 1)
        #expect(before.filter { role(of: $0) == NSAccessibility.Role.button.rawValue }.count == 2)
        let collapse = try #require(before.first { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows" })
        #expect(press(collapse))
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            let current = unique(accessibilityObjects(in: header))
            return current.contains { role(of: $0) == NSAccessibility.Role.headingRole.rawValue && label(of: $0) == "Expand workflows" }
                && current.contains { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Expand workflows" }
        }
        #expect(selections.isEmpty)
        let expanded = unique(accessibilityObjects(in: header))
        #expect(expanded.filter { role(of: $0) == NSAccessibility.Role.headingRole.rawValue && label(of: $0) == "Expand workflows" }.count == 1)
        #expect(expanded.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Expand workflows" }.count == 1)
        #expect(expanded.filter { role(of: $0) == NSAccessibility.Role.button.rawValue }.count == 2)
        let expand = try #require(expanded.first { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Expand workflows" })
        #expect(press(expand))
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            let current = unique(accessibilityObjects(in: header))
            return current.contains { role(of: $0) == NSAccessibility.Role.headingRole.rawValue && label(of: $0) == "Collapse workflows" }
                && current.contains { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows" }
                && current.contains { label(of: $0) == "baseline-definition" }
        }
        let restored = unique(accessibilityObjects(in: header))
        #expect(restored.filter { role(of: $0) == NSAccessibility.Role.headingRole.rawValue && label(of: $0) == "Collapse workflows" }.count == 1)
        #expect(restored.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "Collapse workflows" }.count == 1)
        #expect(restored.filter { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "New workflow" }.count == 1)
        #expect(restored.filter { role(of: $0) == NSAccessibility.Role.button.rawValue }.count == 2)
        let newWorkflow = try #require(restored.first { role(of: $0) == NSAccessibility.Role.button.rawValue && label(of: $0) == "New workflow" })
        #expect(press(newWorkflow))

        // then — creation does not select a task or route through the collapse action.
        #expect(selections.count == 1)
        #expect(selections.compactMap { destination in
            if case .newWorkflow = destination { return destination }
            return nil
        }
.count == 1)
        #expect(unique(accessibilityObjects(in: header)).contains {
            label(of: $0) == "Collapse workflows" && role(of: $0) == NSAccessibility.Role.button.rawValue
        })
    }

    @Test func givenAHeaderCell_whenReconfigured_thenItsHeadingLabelTracksStateWithoutStaleRole() async throws {
        // given — one retained cell is updated in place, as the native coordinator does.
        let cell = SidebarNativeCell(frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        let actions = SidebarNativeActions()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cell
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        // when — collapse state changes, then the same cell becomes an ordinary task row.
        let header = SidebarListEntry(id: "header:workflows", content: .workflowsHeader(expanded: true))
        cell.configure(entry: header, actions: actions, selected: false, animate: false,
                       environment: EnvironmentValues(), onHeight: { _ in })
        await waitUntil { cell.layoutSubtreeIfNeeded(); return label(of: cell) == "Collapse workflows" }
        cell.configure(entry: SidebarListEntry(id: header.id, content: .workflowsHeader(expanded: false)),
                       actions: actions, selected: false, animate: false,
                       environment: EnvironmentValues(), onHeight: { _ in })
        await waitUntil { cell.layoutSubtreeIfNeeded(); return label(of: cell) == "Expand workflows" }
        #expect(cell.accessibilityRole() == .headingRole)
        #expect(cell.accessibilityLabel() == "Expand workflows")

        let item = try #require(SidebarViewModelMock.defaultSections.flatMap(\.items).first)
        cell.configure(entry: SidebarListEntry(id: "task:ordinary", content: .item(item)), actions: actions,
                       selected: false, animate: false, environment: EnvironmentValues(), onHeight: { _ in })
        cell.layoutSubtreeIfNeeded()

        // then — an ordinary source entry cannot retain the header's AX heading role or label.
        #expect(cell.accessibilityRole() != .headingRole)
        #expect(cell.accessibilityLabel() != "Expand workflows")
    }

    private func accessibilityObjects(in object: NSObject) -> [NSObject] {
        var result = [object]
        result += publicAccessibilityChildren(of: object)
        if let view = object as? NSView {
            result += view.subviews.flatMap { accessibilityObjects(in: $0) }
        }
        return result
    }

    private func nativeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { nativeViews(in: $0) }
    }

    private func publicAccessibilityChildren(of object: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return [] }
        return children.compactMap { $0 as? NSObject }.flatMap { child in [child] + publicAccessibilityChildren(of: child) }
    }

    private func label(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityLabel")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func role(of object: NSObject) -> String? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityRole()?.rawValue }
        let selector = NSSelectorFromString("accessibilityRole")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func unique(_ objects: [NSObject]) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return objects.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func press(_ object: NSObject) -> Bool {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Press.self)
        return implementation(object, selector)
    }
}
