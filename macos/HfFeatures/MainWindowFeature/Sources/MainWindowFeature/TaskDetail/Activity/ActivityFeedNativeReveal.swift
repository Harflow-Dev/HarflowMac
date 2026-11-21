import AppKit

// MARK: - Native document reveal

extension ActivityFeedNativeList.Coordinator {
    func revealCallIfNeeded() {
        guard let reveal = model?.callReveal, reveal.token != consumedCallReveal, positioned,
              let table, table.window != nil, let index = entries.firstIndex(where: { $0.id == reveal.rowID }) else { return }
        consumedCallReveal = reveal.token
        state?.anchor = nil
        state?.followLive.suspend()
        writeOffset(table.rect(ofRow: index).minY)
        layoutNow()
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) {
            CallerApprovalNativeFocus.retry(in: cell)
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.actions.onCallScrollAcknowledged(reveal.token)
        }
    }

    func revealApprovalIfNeeded() {
        if model?.scopedApprovalReveals.isEmpty == false {
            // A scroll acknowledgement precedes keyboard focus. Keep that exact source's
            // visible target until focus settles or its row/token is removed or replaced.
            guard !consumedScopedApprovalReveals.contains(where: { scopedApprovalIndex(for: $0) != nil }) else { return }
            if let reveal = model?.scopedApprovalReveals.first(where: {
                !consumedScopedApprovalReveals.contains($0) && scopedApprovalIndex(for: $0) != nil
            }) {
                revealScopedApproval(reveal)
                return
            }
        }
        guard let reveal = model?.approvalReveal, reveal.token != consumedApprovalReveal,
              positioned, let table, table.window != nil,
              let index = entries.firstIndex(where: {
                  if case .scopedApproval(let entry, _) = $0 {
                      return entry.source == model?.approvalSource && entry.card.id == reveal.requestID
                  }
                  return $0.id == "activity-approval-" + reveal.requestID
              }) else { return }
        consumedApprovalReveal = reveal.token
        state?.followLive.suspend()
        writeOffset(table.rect(ofRow: index).minY)
        layoutNow()
        _ = table.view(atColumn: 0, row: index, makeIfNecessary: true)
        let source: ActivityFeedApprovalEntry.Source? = if case .scopedApproval(let entry, _) = entries[index] { entry.source } else { nil }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            if let source {
                actions.onScopedApprovalScrollAcknowledged(source, reveal.requestID, reveal.token)
            } else { actions.onApprovalScrollAcknowledged(reveal.requestID, reveal.token) }
        }
    }

    private func revealScopedApproval(_ reveal: ActivityFeedApprovalReveal) {
        guard positioned, let table, table.window != nil,
              let index = scopedApprovalIndex(for: reveal) else { return }
        consumedScopedApprovalReveals.removeAll { $0.source == reveal.source }
        consumedScopedApprovalReveals.append(reveal)
        state?.followLive.suspend()
        writeOffset(table.rect(ofRow: index).minY)
        layoutNow()
        _ = table.view(atColumn: 0, row: index, makeIfNecessary: true)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.actions.onScopedApprovalScrollAcknowledged(reveal.source, reveal.requestID, reveal.token)
        }
    }

    /// Both pending scrolling and the subsequent focus handshake protect the composer edge.
    /// Stale or superseded intents have no current row and cannot suppress the decoration.
    var hasActionableScopedApprovalReveal: Bool {
        model?.scopedApprovalReveals.contains(where: { scopedApprovalIndex(for: $0) != nil }) == true
            || consumedScopedApprovalReveals.contains(where: { scopedApprovalIndex(for: $0) != nil })
    }

    /// A controller may retain an intent after filtering its request. Only a matching
    /// current row can own scrolling or delay another source's focus handshake.
    func scopedApprovalIndex(for reveal: ActivityFeedApprovalReveal) -> Int? {
        guard model?.scopedApprovalReveals.contains(where: {
            $0.source == reveal.source && $0 != reveal
        }) != true else { return nil }
        return entries.firstIndex {
            guard case .scopedApproval(let entry, _) = $0 else { return false }
            return entry.source == reveal.source && entry.card.id == reveal.requestID
                && entry.card.focusToken == reveal.token
        }
    }

    func schedulePositioningCheck() {
        guard !positioningCheckQueued else { return }
        positioningCheckQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            positioningCheckQueued = false
            maybePerformInitialPositioning()
            revealCallIfNeeded()
            revealApprovalIfNeeded()
            refreshComposerEdge()
            publishPosition()
            maybeLoadOlder()
        }
    }

    func indexRowEntries() {
        firstRowIndex = nil
        lastRowIndex = nil
        historyHeaderIndex = nil
        firstTimelineIndex = nil
        lastTimelineIndex = nil
        for (index, entry) in entries.enumerated() {
            if entry.anchorID != nil {
                if firstRowIndex == nil { firstRowIndex = index }
                lastRowIndex = index
            }
            switch entry {
            case .header: historyHeaderIndex = index
            case .row:
                if firstTimelineIndex == nil { firstTimelineIndex = index }
                lastTimelineIndex = index
            default: break
            }
        }
    }

    func retryHostedFocus() {
        for cell in cells.values {
            guard let id = cell.entryID,
                  id.hasPrefix("activity-approval-") || id.hasPrefix("activity-scoped-approval-")
                      || id.contains("-callSelector-") || id.hasSuffix("-taskContext") else { continue }
            CallerApprovalNativeFocus.retry(in: cell)
        }
    }
}
