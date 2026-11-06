import AppKit
@testable import MainWindowFeature

/// Locates the production observation surface by its reconciled role, never subview order.
@MainActor
func sidebarFixtureOutline(in view: NSView, role: SidebarListPresentation.Role = .recent) -> NSOutlineView? {
    let heading = role == .running ? "header:running" : "header:recent"
    let descendants = [view] + view.subviews.flatMap(sidebarFixtureViews)
    return descendants.compactMap { $0 as? NSOutlineView }.first { outline in
        (0 ..< outline.numberOfRows).contains {
            (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == heading
        }
    }
}

@MainActor
private func sidebarFixtureViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(sidebarFixtureViews)
}
