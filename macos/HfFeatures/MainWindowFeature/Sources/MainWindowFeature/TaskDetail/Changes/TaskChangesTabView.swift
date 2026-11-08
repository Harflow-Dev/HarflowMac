//
//  TaskChangesTabView.swift
//  MainWindowFeature
//
//  The standalone pane's Changes tab (HarflowDesign 17739e4, G-DIFF): repository, then scope, then rows. In this stage
//  rows are plain text, not controls. The view only draws a presentation built elsewhere.
//

import SwiftUI

// MARK: - TaskChangesTabView

/// The Changes tab body. Generic over the screen's view model like the other tabs.
struct TaskChangesTabView<VM: TaskDetailViewModel>: View {
    let viewModel: VM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TaskScreenStyle.PaneBody.gap) {
                switch viewModel.changesPresentation {
                case .loading:
                    ChangesNoteView(note: Self.loadingNote, perform: perform)
                case .note(let note):
                    ChangesNoteView(note: note, perform: perform)
                case .document(let document):
                    ChangesDocumentView(document: document, limits: viewModel.changesRevealLimits,
                                        loadMore: { viewModel.didTapLoadMoreChangeRows(scope: $0) })
                }
            }
            .padding(TaskScreenStyle.PaneBody.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The loading state: "Reading stored changes" over a skeleton, with no count and no zero.
    static var loadingNote: TaskChangesNote { TaskChangesNote(tone: .info, title: "Reading stored changes", skeletonBars: 4) }

    private func perform(_ action: TaskChangesNote.Action) { viewModel.didTapRetryChanges() }
}

// MARK: - ChangesNoteView

/// `.hd-m05-panenote`: a title, detail and reason, optional placeholder bars and an action. A neutral note is a caption.
private struct ChangesNoteView: View {
    let note: TaskChangesNote
    let perform: (TaskChangesNote.Action) -> Void

    var body: some View {
        if note.tone == .neutral {
            Text(verbatim: note.title)
                .font(TaskScreenStyle.sans(size: 12))
                .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            noteText
            if note.skeletonBars > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0 ..< note.skeletonBars, id: \.self) { index in
                        RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusSmall)
                            .fill(TaskScreenStyle.Colors.surfaceActive.color)
                            .frame(height: 14)
                            .scaleEffect(x: max(0.3, 0.88 - Double(index) * 0.11), anchor: .leading)
                    }
                }
                .padding(.top, 8)
                .accessibilityHidden(true)
            }
            if let action = note.action {
                Button(action.title) { perform(action) }
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusMedium).fill(fill))
        .accessibilityElement(children: .contain)
    }

    /// The note's text as one combined element, so its action stays a separately named button.
    private var noteText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: note.title)
                .font(TaskScreenStyle.sans(size: 13).weight(.semibold))
                .foregroundStyle(TaskScreenStyle.Colors.text.color)
            ForEach([note.detail, note.reason].compactMap(\.self), id: \.self) { line in
                Text(verbatim: line)
                    .font(TaskScreenStyle.sans(size: 13))
                    .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
            }
            if let caption = note.caption {
                Text(verbatim: caption)
                    .font(TaskScreenStyle.sans(size: 12))
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(note.skeletonBars > 0 ? .updatesFrequently : [])
    }

    private var fill: Color {
        note.tone == .warn ? TaskScreenStyle.Notice.warning.background.color : TaskScreenStyle.Colors.surfaceSunken.color
    }
}

// MARK: - ChangesDocumentView

/// A listing: an optional banner, one section per repository and the complete-capture caption.
private struct ChangesDocumentView: View {
    let document: TaskChangesDocument
    let limits: [TaskChangesScopeID: Int]
    let loadMore: (TaskChangesScopeID) -> Void

    var body: some View {
        if let banner = document.banner {
            ChangesNoteView(note: banner, perform: { _ in })
        }
        if let attribution = document.repositories.first?.attribution {
            Text(verbatim: attribution)
                .font(TaskScreenStyle.sans(size: 12))
                .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(document.repositories) { repository in
            ChangesRepositoryView(repository: repository, limits: limits, loadMore: loadMore)
        }
        ForEach([document.caption, document.countCaption].compactMap(\.self), id: \.self) { caption in
            Text(verbatim: caption)
                .font(TaskScreenStyle.sans(size: 12))
                .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - ChangesRepositoryView

/// `.hd-m05-repo`: a collapsible repository with its count and tag, then provenance, notes and scopes. The attribution sentence is drawn once above all repositories.
private struct ChangesRepositoryView: View {
    let repository: TaskChangesRepositoryModel
    let limits: [TaskChangesScopeID: Int]
    let loadMore: (TaskChangesScopeID) -> Void
    @State private var isOpen: Bool

    init(repository: TaskChangesRepositoryModel, limits: [TaskChangesScopeID: Int], loadMore: @escaping (TaskChangesScopeID) -> Void) {
        self.repository = repository
        self.limits = limits
        self.loadMore = loadMore
        _isOpen = State(initialValue: repository.startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isOpen { content }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TaskScreenStyle.FactsSummary.borderColor.color).frame(height: TaskScreenStyle.FactsSummary.borderWidth)
        }
    }

    private var header: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(TaskScreenStyle.sans(size: 10).weight(.semibold))
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    .rotationEffect(.degrees(isOpen ? TaskScreenStyle.FactsSummary.expandedChevronDegrees : 0))
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(TaskScreenStyle.sans(size: 12))
                    .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                Text(verbatim: repository.name)
                    .font(TaskScreenStyle.sans(size: 13).weight(.medium))
                    .foregroundStyle(TaskScreenStyle.Colors.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tag = repository.tag { ChangesTagView(tag: tag) }
                Spacer(minLength: 0)
                if let count = repository.count { ChangesCountText(text: count) }
            }
            .frame(minHeight: TaskScreenStyle.FactsSummary.minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(repository.help ?? repository.name)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    @ViewBuilder private var content: some View {
        if !repository.facts.isEmpty {
            DisclosureGroup("Provenance") {
                FactsGrid {
                    ForEach(repository.facts, id: \.term) { fact in factsRow(fact.term, fact.value) }
                }
            }
            .font(TaskScreenStyle.sans(size: 12))
            .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
        }
        ForEach(Array(repository.notes.enumerated()), id: \.offset) { _, note in
            ChangesNoteView(note: note, perform: { _ in })
        }
        ForEach(repository.scopes) { scope in
            ChangesScopeView(scope: scope, limit: limits[scope.id] ?? TaskChangesPresentationBuilder.revealStep, loadMore: loadMore)
        }
    }
}

// MARK: - ChangesScopeView

/// `.hd-m05-scope`: a heading with its count and tag, captions, then the revealed rows.
private struct ChangesScopeView: View {
    let scope: TaskChangesScopeModel
    let limit: Int
    let loadMore: (TaskChangesScopeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: scope.title)
                    .font(TaskScreenStyle.sans(size: 12).weight(.medium))
                    .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                if let count = scope.count { ChangesCountText(text: count) }
                if let tag = scope.tag { ChangesTagView(tag: tag) }
            }
            .padding(.vertical, 2)
            ForEach(scope.captions, id: \.self) { caption in
                Text(verbatim: caption)
                    .font(TaskScreenStyle.sans(size: 12))
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scope.rows.prefix(limit))) { row in ChangesRowView(row: row) }
            }
            if scope.rows.count > limit {
                HStack(spacing: 8) {
                    Text("Showing \(limit) of \(scope.rows.count) rows")
                        .font(TaskScreenStyle.sans(size: 12))
                        .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    Button("Load more rows") { loadMore(scope.id) }.controlSize(.small)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - ChangesRowView

/// `.hd-file.hd-m05-file`: status letter, path, row state and counts. Not a control in this stage.
private struct ChangesRowView: View {
    let row: TaskChangesRowModel

    var body: some View {
        let style = TaskScreenStyle.ChangeRow.self
        HStack(spacing: style.gap) {
            Text(verbatim: row.letter)
                .font(TaskScreenStyle.mono(size: style.statusSize, weight: .semibold))
                .foregroundStyle(statusColor.color)
                .frame(width: style.statusWidth)
            Text(verbatim: row.path)
                .font(TaskScreenStyle.mono(size: style.pathSize))
                .foregroundStyle(TaskScreenStyle.Colors.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let state = row.state {
                Text(verbatim: state)
                    .font(TaskScreenStyle.sans(size: style.rowStateSize))
                    .foregroundStyle(style.rowStateColor.color)
                    .lineLimit(1)
                    .frame(maxWidth: style.rowStateMaxWidth, alignment: .trailing)
            }
            if let additions = row.additions {
                Text(verbatim: "+\(additions)")
                    .font(TaskScreenStyle.sans(size: style.countSize))
.monospacedDigit()
                    .foregroundStyle(style.addColor.color)
            }
            if let deletions = row.deletions {
                Text(verbatim: "−\(deletions)")
                    .font(TaskScreenStyle.sans(size: style.countSize))
.monospacedDigit()
                    .foregroundStyle(style.deleteColor.color)
            }
        }
        .padding(.horizontal, style.compactPaddingHorizontal)
        .frame(height: style.compactHeight)
        .opacity(row.isDimmed ? style.dimOpacity : 1)
        .modifier(OptionalHelp(text: row.stateHelp))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var statusColor: TaskScreenStyle.Token {
        let style = TaskScreenStyle.ChangeRow.self
        switch row.letter {
        case "A": return style.statusAdded
        case "D": return style.statusDeleted
        case "M": return style.statusModified
        case "U": return style.statusUnmerged
        default: return style.statusColor
        }
    }

    private var accessibilityText: String {
        var parts = [row.statusWord, row.path]
        if let state = row.state { parts.append(state) }
        if let additions = row.additions { parts.append("\(additions) added") }
        if let deletions = row.deletions { parts.append("\(deletions) removed") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - ChangesTagView

/// `.hd-m05-tag`: 18 point high, 11 point medium.
private struct ChangesTagView: View {
    let tag: TaskChangesTag

    var body: some View {
        let style = TaskScreenStyle.ChangeTag.self
        let pair: TaskScreenStyle.ColorPair = switch tag.tone {
        case .warn: style.warn
        case .info: style.info
        case .neutral: style.base
        }
        Text(verbatim: tag.text)
            .font(TaskScreenStyle.sans(size: style.fontSize).weight(style.weight))
            .foregroundStyle(pair.foreground.color)
            .lineLimit(1)
            .padding(.horizontal, style.paddingHorizontal)
            .frame(height: style.height)
            .background(RoundedRectangle(cornerRadius: style.cornerRadius).fill(pair.background.color))
            .fixedSize()
    }
}

// MARK: - ChangesCountText

/// `.hd-tab__count`: 12 point, tertiary, tabular numerals.
private struct ChangesCountText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(TaskScreenStyle.sans(size: TaskScreenStyle.PaneTab.countSize))
            .monospacedDigit()
            .foregroundStyle(TaskScreenStyle.PaneTab.countColor.color)
    }
}

// MARK: - OptionalHelp

/// Hover help only when there is something to say, so an ordinary row carries no hover affordance.
private struct OptionalHelp: ViewModifier {
    let text: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
