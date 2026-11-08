//
//  TaskTopBarHolder.swift
//  MainWindowFeature
//
//  The transport that carries a standalone task's top bar content from the mounted task view to the window's
//  principal toolbar item. The shell passes the holder down and never reads it; only `TaskTopBarPrincipal` reads
//  `shown`, so a content change re-evaluates that child and nothing above it.
//

import Foundation
import Observation

// MARK: - TaskTopBarHolder

/// Owned by the main window coordinator. A writer is identified by `Tag`: its object identity plus the
/// normalised conversation id, so a late write from an outgoing view, or from an earlier generation of the
/// same conversation, can be stored but is never shown.
@MainActor
@Observable
public final class TaskTopBarHolder {

    /// One writer: the VM's identity and the conversation it was built for.
    struct Tag: Hashable, Sendable {
        let writer: ObjectIdentifier
        let conversationID: String
    }

    /// The content the principal draws, `nil` when no active writer has published for the shown conversation.
    /// Written only when it changes.
    private(set) var shown: TaskTopBarContent?
    /// The conversation the window shows as a task, `nil` for every other selection.
    @ObservationIgnored private(set) var shownConversation: String?
    /// The only writer whose content is shown.
    @ObservationIgnored private(set) var activeTag: Tag?
    @ObservationIgnored private var entries: [Tag: TaskTopBarContent] = [:]

    /// Creates an empty holder.
    public init() {}

    /// Records `content` for `tag`.
    func publish(_ content: TaskTopBarContent, tag: Tag) {
        entries[tag] = content
        refreshShown()
    }

    /// Removes `tag`'s entry only.
    func clear(tag: Tag) {
        guard entries.removeValue(forKey: tag) != nil else { return }
        refreshShown()
    }

    /// Makes `tag` the shown writer when its conversation is the shown one. Returns whether it was accepted.
    @discardableResult
    func activate(_ tag: Tag) -> Bool {
        guard tag.conversationID == shownConversation else { return false }
        if activeTag != tag { activeTag = tag }
        refreshShown()
        return true
    }

    /// A retry: makes `tag` the shown writer only when the slot is vacant (no active tag, or one for another
    /// conversation). It never replaces a different active writer of the same conversation.
    @discardableResult
    func activateIfVacant(_ tag: Tag) -> Bool {
        guard tag.conversationID == shownConversation else { return false }
        if activeTag == tag { return true }
        guard activeTag == nil || activeTag?.conversationID != shownConversation else { return false }
        return activate(tag)
    }

    /// Deactivates `tag` if it is the active writer.
    func deactivate(_ tag: Tag) {
        guard activeTag == tag else { return }
        activeTag = nil
        refreshShown()
    }

    /// Sets the shown conversation. A change drops the active writer and prunes entries of other conversations,
    /// so one conversation's content never flashes over another's.
    func setShownConversation(_ conversation: String?) {
        guard shownConversation != conversation else { return }
        shownConversation = conversation
        activeTag = nil
        entries = entries.filter { $0.key.conversationID == conversation }
        refreshShown()
    }

    private func refreshShown() {
        let next: TaskTopBarContent? = if let activeTag, activeTag.conversationID == shownConversation { entries[activeTag] } else { nil }
        if shown != next { shown = next }
    }
}
