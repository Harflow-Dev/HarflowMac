import Foundation

// MARK: - Sidebar empty state

extension SidebarVM {
    /// Plan review round 1, item 4 / Codex review round 1, finding 3: a shimmer instead of an empty
    /// list, but only before anything else already occupies that space — same precedence order
    /// `computeEmptyStateMessage()` uses for its own first guard.
    ///
    /// Not `private`: `SidebarVM+InstallBanner.swift`'s `recomputeInstallBanner()` calls this too,
    /// same reasoning as `computeEmptyStateMessage()` above — an install banner can appear or clear
    /// before the first listing arrives (via `installStatePublisher()`/etc., none of which call
    /// `recompute()`), and `showsLoadingSkeleton` must not go stale until some unrelated event
    /// happens to recompute it.
    func computeShowsLoadingSkeleton() -> Bool {
        !latestHasListed && latestListError == nil && installBannerModel == nil
    }

    /// Empty-state precedence (Review round 1 item 3): the connection/loading/listing-error/banner
    /// UI gates first — the view shows that instead, so this is only reached once there's genuinely
    /// nothing else to show; any filtered content (running, parallel groups, or recent) suppresses
    /// the message entirely; a non-blank (trimmed) search always wins next; only then does the
    /// selected backend's own reported availability decide the copy.
    ///
    /// Not `private`: `SidebarVM+InstallBanner.swift`'s `recomputeInstallBanner()` calls this too
    /// (Code review round 1, finding 4) — `private` is file-scoped in Swift, same reasoning as
    /// `installState`/`lastCheckMessage` etc. above.
    func computeEmptyStateMessage() -> String? {
        guard latestHasListed, latestListError == nil, installBannerModel == nil else { return nil }
        guard sections.isEmpty else { return nil }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty else { return "No tasks match \"\(trimmedQuery)\"." }

        guard selectedBackend != "all" else {
            return "No tasks yet. Tasks started through polybridge appear here."
        }
        if latestCatalog.entries.first(where: { $0.backend == selectedBackend })?.installed == false {
            return "\(selectedBackend) wasn't found on your PATH — install its CLI to run \(selectedBackend) tasks."
        }
        return "No \(selectedBackend) tasks yet."
    }

}
