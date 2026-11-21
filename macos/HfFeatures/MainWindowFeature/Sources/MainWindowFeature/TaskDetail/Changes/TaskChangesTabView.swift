//
//  TaskChangesTabView.swift
//  MainWindowFeature
//
//  The standalone pane's Changes tab (HarflowDesign 17739e4, G-DIFF): repository, then scope, then rows. In this stage
//  stored text opens inline beneath its exact file row.
//

import MonitorCore
import SwiftUI

// MARK: - TaskChangesTabView

/// The Changes tab body. Generic over the screen's view model like the other tabs.
struct TaskChangesTabView<VM: TaskDetailViewModel>: View {
    let viewModel: VM
    @FocusState private var focused: ChangesFocus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TaskScreenStyle.PaneBody.gap) {
                if let turns = viewModel.changesTurns {
                    ChangesTurnBar(turns: turns, select: { viewModel.didSelectChangesTurn($0) })
                }
                switch viewModel.changesPresentation {
                case .loading:
                    ChangesNoteView(note: Self.loadingNote, perform: perform)
                case .note(let note):
                    ChangesNoteView(note: note, perform: perform)
                case .document(let document):
                    ChangesDocumentView(document: document, limits: viewModel.changesRevealLimits,
                                        selected: viewModel.changesSelection, diff: viewModel.changesDiff, focused: $focused, perform: perform,
                                        loadMore: { viewModel.didTapLoadMoreChangeRows(scope: $0) },
                                        select: { viewModel.didSelectChangesRow($0) },
                                        collapse: { viewModel.didCollapseChangesRow($0) })
                }
                if case .failure(_, let note) = viewModel.changesDiff, note.action == .reloadChanges {
                    ChangesDiffView(diff: viewModel.changesDiff, perform: perform)
                }
            }
            .padding(TaskScreenStyle.PaneBody.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The loading state: "Reading stored changes" over a skeleton, with no count and no zero.
    static var loadingNote: TaskChangesNote { TaskChangesNote(tone: .info, title: "Reading stored changes", skeletonBars: 4) }

    private func perform(_ action: TaskChangesNote.Action) {
        switch action {
        case .retryRead, .checkAgain: viewModel.didTapRetryChanges()
        case .retryDiff: viewModel.didTapRetryChangesDiff()
        case .reloadChanges: viewModel.didTapReloadChanges()
        }
    }
}

enum ChangesFocus: Hashable {
    case row(TaskChangesSelection)
    case retry(TaskChangesSelection)
}

// MARK: - ChangesNoteView

/// `.hd-m05-panenote`: a title, detail and reason, optional placeholder bars and an action. A neutral note is a caption.
struct ChangesNoteView: View {
    let note: TaskChangesNote
    let perform: (TaskChangesNote.Action) -> Void
    var retryFocus: FocusState<ChangesFocus?>.Binding?
    var selection: TaskChangesSelection?

    var body: some View {
        if note.tone == .neutral {
            VStack(alignment: .leading, spacing: 8) {
                if !note.title.isEmpty {
                    Text(verbatim: note.title)
                        .font(TaskScreenStyle.sans(size: 12))
                        .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                skeleton
            }
        } else {
            card
        }
    }

    /// Placeholder bars, drawn by every tone.
    @ViewBuilder private var skeleton: some View {
        if note.skeletonBars > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0 ..< note.skeletonBars, id: \.self) { index in
                    RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusSmall)
                        .fill(TaskScreenStyle.Colors.surfaceActive.color)
                        .frame(height: 14)
                        .scaleEffect(x: max(0.3, 0.88 - Double(index) * 0.11), anchor: .leading)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            noteText
            skeleton.padding(.top, 8)
            if let action = note.action {
                if let retryFocus, let selection, action == .retryDiff {
                    Button(action.title) { perform(action) }
                        .focused(retryFocus, equals: .retry(selection))
                        .controlSize(.small)
                        .padding(.top, 8)
                } else {
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                        .padding(.top, 8)
                }
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
    let selected: TaskChangesSelection?
    let diff: TaskChangesDiffPresentation
    let focused: FocusState<ChangesFocus?>.Binding
    let perform: (TaskChangesNote.Action) -> Void
    let loadMore: (TaskChangesScopeID) -> Void
    let select: (TaskChangesSelector) -> Void
    let collapse: (TaskChangesSelector) -> Void

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
            ChangesRepositoryView(repository: repository, limits: limits, selected: selected, diff: diff, focused: focused, perform: perform,
                                  loadMore: loadMore, select: select, collapse: collapse)
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
    let selected: TaskChangesSelection?
    let diff: TaskChangesDiffPresentation
    let focused: FocusState<ChangesFocus?>.Binding
    let perform: (TaskChangesNote.Action) -> Void
    let loadMore: (TaskChangesScopeID) -> Void
    let select: (TaskChangesSelector) -> Void
    let collapse: (TaskChangesSelector) -> Void
    @State private var isOpen: Bool

    init(repository: TaskChangesRepositoryModel, limits: [TaskChangesScopeID: Int], selected: TaskChangesSelection?,
         diff: TaskChangesDiffPresentation, focused: FocusState<ChangesFocus?>.Binding,
         perform: @escaping (TaskChangesNote.Action) -> Void, loadMore: @escaping (TaskChangesScopeID) -> Void,
         select: @escaping (TaskChangesSelector) -> Void, collapse: @escaping (TaskChangesSelector) -> Void) {
        self.repository = repository; self.limits = limits; self.selected = selected; self.diff = diff
        self.focused = focused; self.perform = perform; self.loadMore = loadMore; self.select = select; self.collapse = collapse
        _isOpen = State(initialValue: repository.startsOpen || Self.contains(repository, selected))
    }

    private static func contains(_ repository: TaskChangesRepositoryModel, _ selection: TaskChangesSelection?) -> Bool {
        guard let selection else { return false }
        return repository.scopes.contains { $0.id.taskID == selection.taskID && $0.rows.contains { $0.selector == selection.selector } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isOpen { content }
        }
        .onChange(of: selected) { _, selection in
            if Self.contains(repository, selection) { isOpen = true }
        }
        .onChange(of: repository) { _, repository in
            if Self.contains(repository, selected) { isOpen = true }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TaskScreenStyle.FactsSummary.borderColor.color).frame(height: TaskScreenStyle.FactsSummary.borderWidth)
        }
    }

    private var header: some View {
        Button {
            if isOpen, Self.contains(repository, selected), let selector = selected?.selector { collapse(selector) }
            isOpen.toggle()
        } label: {
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
            ChangesScopeView(scope: scope, limit: limits[scope.id] ?? TaskChangesPresentationBuilder.revealStep, selected: selected,
                             diff: diff, focused: focused, perform: perform, loadMore: loadMore, select: select, collapse: collapse)
        }
    }
}

// MARK: - ChangesScopeView

/// `.hd-m05-scope`: a heading with its count and tag, captions, then the revealed rows.
private struct ChangesScopeView: View {
    let scope: TaskChangesScopeModel
    let limit: Int
    let selected: TaskChangesSelection?
    let diff: TaskChangesDiffPresentation
    let focused: FocusState<ChangesFocus?>.Binding
    let perform: (TaskChangesNote.Action) -> Void
    let loadMore: (TaskChangesScopeID) -> Void
    let select: (TaskChangesSelector) -> Void
    let collapse: (TaskChangesSelector) -> Void
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
                ForEach(Array(scope.rows.prefix(limit)).map { IdentifiedChangesRow(row: $0, member: scope.id.taskID) }) { item in
                    let row = item.row
                    let selection = row.selector.map { TaskChangesSelection(taskID: scope.id.taskID, selector: $0) }
                    let isSelected = selection != nil && selection == selected
                    ChangesRowView(row: row, member: scope.id.taskID, isSelected: isSelected, focused: focused, select: select, collapse: collapse)
                    if isSelected, let selection {
                        ChangesDiffView(diff: diff, perform: { action in
                            if action == .retryDiff, focused.wrappedValue == .retry(selection) {
                                focused.wrappedValue = .row(selection)
                            }
                            perform(action)
                        }, retryFocus: focused, selection: selection)
                    }
                }
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

private enum ChangesRowIdentity: Hashable {
    case selector(TaskChangesSelection)
    case position(Int)
}

private struct IdentifiedChangesRow: Identifiable {
    let row: TaskChangesRowModel
    let member: String
    var id: ChangesRowIdentity {
        row.selector.map { .selector(TaskChangesSelection(taskID: member, selector: $0)) } ?? .position(row.id)
    }
}

// MARK: - ChangesRowView

/// A file disclosure for stored text, or a descriptive row when text cannot be disclosed.
private struct ChangesRowView: View {
    let row: TaskChangesRowModel
    let member: String
    let isSelected: Bool
    let focused: FocusState<ChangesFocus?>.Binding
    let select: (TaskChangesSelector) -> Void
    let collapse: (TaskChangesSelector) -> Void
    @State private var isHovering = false

    var body: some View {
        if let selector = row.selector {
        Button {
            if isSelected { collapse(selector) } else { select(selector) }
        } label: {
            content
                .background(RoundedRectangle(cornerRadius: TaskScreenStyle.ChangeRow.cornerRadius).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: TaskScreenStyle.ChangeRow.cornerRadius))
        }
        .buttonStyle(.plain)
        .focused(focused, equals: .row(TaskChangesSelection(taskID: member, selector: selector)))
        .onHover { isHovering = $0 }
        .modifier(OptionalHelp(text: row.stateHelp))
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(isSelected ? "Expanded" : "Collapsed")
        } else {
            content
                .modifier(OptionalHelp(text: row.stateHelp))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var fill: Color {
        let style = TaskScreenStyle.ChangeRow.self
        if isSelected { return style.selectedFill.color }
        return isHovering && row.selector != nil ? style.hoverFill.color : .clear
    }

    private var content: some View {
        let style = TaskScreenStyle.ChangeRow.self
        return HStack(spacing: style.gap) {
            Image(systemName: "chevron.right")
                .font(TaskScreenStyle.sans(size: 9).weight(.semibold))
                .rotationEffect(.degrees(isSelected ? 90 : 0))
                .frame(width: 10)
                .opacity(row.selector == nil ? 0 : 1)
                .accessibilityHidden(true)
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
struct ChangesTagView: View {
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

// MARK: - ChangesTurnBar

/// `.hd-m05-turnbar`: which turn's capture is shown, newest first, with the caption that turns are not added together.
private struct ChangesTurnBar: View {
    let turns: TaskChangesTurnPicker
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TaskScreenStyle.PaneBody.gap) {
            HStack(spacing: 8) {
                Text("Showing")
                    .font(TaskScreenStyle.sans(size: 12))
                    .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                Picker("Turn", selection: Binding(get: { turns.selectedID }, set: select)) {
                    ForEach(turns.options) { option in Text(verbatim: option.title).tag(option.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Turn")
                Spacer(minLength: 0)
                Text(verbatim: "task " + turns.shortID)
                    .font(TaskScreenStyle.mono(size: 11))
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
            }
            Text(verbatim: TaskChangesTurnPicker.caption)
                .font(TaskScreenStyle.sans(size: 12))
                .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
