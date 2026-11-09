import Foundation

// MARK: - Sidebar empty state

extension SidebarVM {
    /// A shimmer instead of an empty list, but only before the first listing arrives and while no
    /// list error occupies that space — same precedence order `computeEmptyStateMessage()` uses
    /// for its own first guard.
    ///
    /// Not `private`: the list-error subscription in `SidebarVM+Subscription.swift` calls this too,
    /// so `showsLoadingSkeleton` is refreshed immediately even while presentation is off.
    func computeShowsLoadingSkeleton() -> Bool {
        !latestHasListed && latestListError == nil
    }

    /// Empty-state precedence (Review round 1 item 3): the connection/loading/listing-error
    /// UI gates first — the view shows that instead, so this is only reached once there's genuinely
    /// nothing else to show; any filtered content (running, parallel groups, or recent) suppresses
    /// the message entirely; a non-blank (trimmed) search always wins next; only then does the
    /// selected backend's own reported availability decide the copy.
    ///
    /// Not `private`: the list-error subscription in `SidebarVM+Subscription.swift` calls this too —
    /// `private` is file-scoped in Swift.
    func computeEmptyStateMessage() -> String? {
        guard latestHasListed, latestListError == nil else { return nil }
        guard sections.isEmpty else { return nil }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty else { return "No tasks match \"\(trimmedQuery)\"." }

        guard selectedBackend != "all" else {
            return "No tasks yet. Tasks started through harflow appear here."
        }
        if latestCatalog.entries.first(where: { $0.backend == selectedBackend })?.installed == false {
            return "\(selectedBackend) wasn't found on your PATH — install its CLI to run \(selectedBackend) tasks."
        }
        return "No \(selectedBackend) tasks yet."
    }

}
