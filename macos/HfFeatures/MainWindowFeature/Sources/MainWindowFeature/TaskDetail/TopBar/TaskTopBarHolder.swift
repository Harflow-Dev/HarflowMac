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

// MARK: - TopBarSubject

/// What the window's top bar shows content for: a standalone task's conversation, or a Parallel group by name.
enum TopBarSubject: Hashable, Sendable {
    case task(String)
    case group(String)
}

// MARK: - TaskTopBarHolder

/// Owned by the main window coordinator. A writer is identified by `Tag`: its object identity plus the subject it
/// was built for, so a late write from an outgoing view, or from an earlier generation of the same subject, can be
/// stored but is never shown. Task content and group content travel the same way: `shown` for a task,
/// `shownGroup` for a group, each written only when its content changes.
@MainActor
@Observable
public final class TaskTopBarHolder {

    /// One writer: the VM's identity and the subject it was built for.
    struct Tag: Hashable, Sendable {
        let writer: ObjectIdentifier
        let subject: TopBarSubject

        init(writer: ObjectIdentifier, subject: TopBarSubject) {
            self.writer = writer
            self.subject = subject
        }

        /// A standalone task writer.
        init(writer: ObjectIdentifier, conversationID: String) {
            self.init(writer: writer, subject: .task(conversationID))
        }

        /// The task conversation id, or the group name.
        var conversationID: String {
            switch subject {
            case .task(let id): id
            case .group(let name): name
            }
        }
    }

    /// What one writer published.
    enum Content: Equatable, Sendable {
        case task(TaskTopBarContent)
        case group(GroupTopBarContent)
    }

    /// The task content the principal draws, `nil` when no active writer has published for the shown conversation.
    /// Written only when it changes.
    private(set) var shown: TaskTopBarContent?
    /// The group content the principal draws, `nil` when no active group writer has published for the shown group.
    private(set) var shownGroup: GroupTopBarContent?
    /// The subject the window shows content for, `nil` for every other selection.
    @ObservationIgnored private(set) var shownSubject: TopBarSubject?
    /// The only writer whose content is shown.
    @ObservationIgnored private(set) var activeTag: Tag?
    @ObservationIgnored private var entries: [Tag: Content] = [:]

    /// The conversation the window shows as a task, `nil` for every other selection.
    var shownConversation: String? {
        if case .task(let id) = shownSubject { id } else { nil }
    }

    /// Creates an empty holder.
    public init() {}

    /// Records task `content` for `tag`.
    func publish(_ content: TaskTopBarContent, tag: Tag) {
        entries[tag] = .task(content)
        refreshShown()
    }

    /// Records group `content` for `tag`.
    func publish(_ content: GroupTopBarContent, tag: Tag) {
        entries[tag] = .group(content)
        refreshShown()
    }

    /// Removes `tag`'s entry only.
    func clear(tag: Tag) {
        guard entries.removeValue(forKey: tag) != nil else { return }
        refreshShown()
    }

    /// Makes `tag` the shown writer when its subject is the shown one. Returns whether it was accepted.
    @discardableResult
    func activate(_ tag: Tag) -> Bool {
        guard tag.subject == shownSubject else { return false }
        if activeTag != tag { activeTag = tag }
        refreshShown()
        return true
    }

    /// A retry: makes `tag` the shown writer only when the slot is vacant (no active tag, or one for another
    /// subject). It never replaces a different active writer of the same subject.
    @discardableResult
    func activateIfVacant(_ tag: Tag) -> Bool {
        guard tag.subject == shownSubject else { return false }
        if activeTag == tag { return true }
        guard activeTag == nil || activeTag?.subject != shownSubject else { return false }
        return activate(tag)
    }

    /// Deactivates `tag` if it is the active writer.
    func deactivate(_ tag: Tag) {
        guard activeTag == tag else { return }
        activeTag = nil
        refreshShown()
    }

    /// Sets the shown conversation (a task subject).
    func setShownConversation(_ conversation: String?) {
        setShownSubject(conversation.map(TopBarSubject.task))
    }

    /// Sets the shown subject. A change drops the active writer and prunes entries of other subjects, so one
    /// subject's content never flashes over another's (group(a) to group(b) drops the active tag too).
    func setShownSubject(_ subject: TopBarSubject?) {
        guard shownSubject != subject else { return }
        shownSubject = subject
        activeTag = nil
        entries = entries.filter { $0.key.subject == subject }
        refreshShown()
    }

    private func refreshShown() {
        let content: Content? = if let activeTag, activeTag.subject == shownSubject { entries[activeTag] } else { nil }
        var task: TaskTopBarContent?
        var group: GroupTopBarContent?
        switch content {
        case .task(let value): task = value
        case .group(let value): group = value
        case nil: break
        }
        if shown != task { shown = task }
        if shownGroup != group { shownGroup = group }
    }
}
