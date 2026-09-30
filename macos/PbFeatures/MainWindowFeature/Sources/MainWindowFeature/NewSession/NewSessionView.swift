//
//  NewSessionView.swift
//  MainWindowFeature
//
//  Headless-only: defaults are claude/read_only with an empty repo/message; a non-blank message is
//  required to start; the repo path is validated by the VM (`NewSessionUseCase.resolvedRepoPath`);
//  success dismisses the sheet, failure stays inline.
//

import PbCommon
import PbUI
import SwiftUI

// MARK: - NewSessionViewModel

/// View model protocol for the New Session sheet.
@MainActor
protocol NewSessionViewModel: ViewModel {

    var backend: String { get }
    var repo: String { get }
    var freedom: String { get }
    var message: String { get }
    var name: String { get }
    var model: String { get }
    var turnLimit: String { get }
    /// Why the Turn limit blocks Start, shown under the field; `nil` when it doesn't.
    var turnLimitError: String? { get }
    var effort: String { get }
    var errorText: String? { get }
    var isStarting: Bool { get }
    var canStart: Bool { get }
    var agentCards: [AgentCardModel] { get }
    var recentRepos: [RecentRepoModel] { get }
    var accessOptions: [AccessOptionModel] { get }
    var effortOptions: [String] { get }
    var showsEffort: Bool { get }
    var showsModel: Bool { get }
    /// "Default" first, then the agent's known models.
    var modelChoices: [ModelChoiceModel] { get }
    /// Explains why there is no Model control; `nil` when there is one.
    var modelUnavailableNote: String? { get }
    var showsTurnLimit: Bool { get }
    var agentNotFoundNote: String? { get }
    var agentListUnavailableNote: String? { get }

    func didAppear()
    func didDisappear()
    func didChangeBackend(_ value: String)
    func didChangeRepo(_ value: String)
    func didChangeFreedom(_ value: String)
    func didChangeMessage(_ value: String)
    func didChangeName(_ value: String)
    func didChangeModel(_ value: String)
    func didChangeTurnLimit(_ value: String)
    func didChangeEffort(_ value: String)
    func didTapRecentRepo(_ path: String)
    func didTapChooseDirectory()
    func didTapCancel()
    func didTapStart()
}

// MARK: - NewSessionView

struct NewSessionView<VM: NewSessionViewModel>: View {

    // MARK: - Environment

    @Environment(\.viewEvent) var viewEvent

    // MARK: - State

    @State var viewModel: VM
    @State private var isAdvancedExpanded = false
    @FocusState private var isPromptFocused: Bool

    // MARK: - Init

    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }

    // MARK: - View Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    taskSection
                    agentSection
                    repositorySection
                    accessSection
                    advancedSection
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            footer
        }
        .frame(width: 600)
        .frame(minHeight: 420, idealHeight: 860, maxHeight: 920)
        .background(Color.windowBG)
        .onAppear {
            viewModel.didAppear()
            isPromptFocused = true
        }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // swiftlint:disable:next no_literal_font_size - the design's 20 pt sheet title sits between the scale's title (18) and hero (22).
            Text("New session").font(.system(size: 20, weight: .semibold))
            Text("Start an agent on one of your repos. It runs in the background and shows up in the sidebar.")
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What should it do?")
            promptEditor
            HStack(spacing: 12) {
                Text("Name").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                TextField("Optional — shown in the sidebar, e.g. MT-2477 iOS review", text: binding(\.name, viewModel.didChangeName))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
            }
        }
    }

    private var promptEditor: some View {
        TextEditor(text: binding(\.message, viewModel.didChangeMessage))
            .font(.pb(.body))
            .scrollContentBackground(.hidden)
            .focused($isPromptFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(height: 112)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.composerFill))
            .overlay(alignment: .topLeading) {
                if viewModel.message.isEmpty {
                    Text("Describe the task, like you would to a colleague…")
                        .font(.pb(.body))
                        .foregroundStyle(Color.secondaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: PbRadius.card)
                    .stroke(isPromptFocused ? Color.accentLink.opacity(0.6) : Color.cardBorder, lineWidth: 1)
            )
            .shadow(color: isPromptFocused ? Color.accentLink.opacity(0.18) : .clear, radius: 3)
            .accessibilityLabel("What should it do?")
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Agent")
            AgentGrid(cards: viewModel.agentCards, onSelect: viewModel.didChangeBackend)
            if let note = viewModel.agentListUnavailableNote {
                Text(note).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            } else if let note = viewModel.agentNotFoundNote {
                Text(note).font(.pb(.caption)).foregroundStyle(Color.warningFG)
            }
        }
    }

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Repository")
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(Color.secondaryText)
                    TextField("/path/to/repo", text: binding(\.repo, viewModel.didChangeRepo))
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Repository path")
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.composerFill))
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                Button("Choose…") { viewModel.didTapChooseDirectory() }
                    .buttonStyle(QuietButtonStyle())
            }
            RecentRepos(repos: viewModel.recentRepos, onSelect: viewModel.didTapRecentRepo)
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What can it change?")
            VStack(spacing: 12) {
                ForEach(viewModel.accessOptions) { option in
                    AccessOptionRow(model: option) { viewModel.didChangeFreedom(option.id) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What can it change?")
            Text("How strictly this is enforced depends on the agent. The task's Technical info shows exactly what applied.")
                .font(.pb(.caption))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isAdvancedExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.pb(.caption, weight: .semibold))
                        .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                    Text("Advanced — model, effort, turn limit").font(.pb(.secondary))
                }
                .foregroundStyle(Color.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isAdvancedExpanded ? "expanded" : "collapsed")
            if isAdvancedExpanded {
                advancedFields
            }
        }
    }

    private var advancedFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
            if viewModel.showsEffort {
                GridRow {
                    Text("Reasoning effort").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                    Picker("Reasoning effort", selection: binding(\.effort, viewModel.didChangeEffort)) {
                        Text("Default").tag("")
                        ForEach(viewModel.effortOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160, alignment: .leading)
                }
            }
            if viewModel.showsModel {
                GridRow {
                    Text("Model").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                    ModelCombo(text: viewModel.model, choices: viewModel.modelChoices, onChange: viewModel.didChangeModel)
                }
            }
            if let note = viewModel.modelUnavailableNote {
                GridRow {
                    Text("Model").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                    Text(note).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                }
            }
            if viewModel.showsTurnLimit {
                GridRow {
                    Text("Turn limit").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Empty uses the default", text: binding(\.turnLimit, viewModel.didChangeTurnLimit))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .accessibilityLabel("Turn limit")
                        if let error = viewModel.turnLimitError {
                            Text(error).font(.pb(.caption)).foregroundStyle(Color.failedRed)
                        }
                    }
                }
            }
        }
        .padding(.leading, 15)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text("⌘↩ to start").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Spacer()
                Button("Cancel") { viewModel.didTapCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(viewModel.isStarting ? "Starting…" : "Start session") { viewModel.didTapStart() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!viewModel.canStart)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.pb(.body, weight: .semibold))
    }

    private func binding(_ keyPath: KeyPath<VM, String>, _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { viewModel[keyPath: keyPath] }, set: set)
    }
}

#if DEBUG
private struct NewSessionPreview: View {
    let viewModel: NewSessionViewModelMock
    var body: some View { NewSessionView(viewModel) }
}

#Preview("New session - light") {
    NewSessionPreview(viewModel: NewSessionViewModelMock.sample).preferredColorScheme(.light)
}

#Preview("New session - dark") {
    NewSessionPreview(viewModel: NewSessionViewModelMock.sample).preferredColorScheme(.dark)
}
#endif
