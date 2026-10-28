//
//  NewSessionView.swift
//  MainWindowFeature
//
//  Headless-only: defaults are claude/read_only with an empty repo/message; a non-blank message is
//  required to start; the repo path is validated by the VM (`NewSessionUseCase.resolvedRepoPath`);
//  success dismisses the sheet, failure stays inline.
//

import HfCommon
import HfUI
import SwiftUI

// MARK: - NewSessionViewModel

/// View model protocol for the New Session sheet.
@MainActor
protocol NewSessionViewModel: ViewModel {
    var qualificationCards: [QualificationCard] { get }
    func didTapQualification()

    var backend: String { get }
    var repo: String { get }
    var freedom: String { get }
    var message: String { get }
    var name: String { get }
    var model: String { get }
    var turnLimit: String { get }
    var callerApprovals: Bool { get }
    var supportsCallerApprovals: Bool { get }
    var callerApprovalError: String? { get }
    var approvalNote: String? { get }
    func didChangeCallerApprovals(_ value: Bool)
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
        VStack(spacing: HfRadius.Metrics.zero) {
            // The compact default (collapsed Advanced) fits a 900 pt window without scrolling;
            // the ScrollView stays as the fallback for an expanded Advanced, errors, long text, a
            // larger catalog or a narrow window — nothing is clipped or removed.
            ScrollView {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing20) {
                    header
                    taskSection
                    agentSection
                    repositorySection
                    accessSection
                    advancedSection
                }
                .padding(.horizontal, HfRadius.Metrics.spacing28)
                .padding(.top, HfRadius.Metrics.spacing24)
                .padding(.bottom, HfRadius.Metrics.spacing16)
                // The document probe (§6.6): inside the fallback scroll's own document, so it can
                // only ever target this outer scroll view — never the prompt editor's.
                .background(ScrollChrome())
            }
            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HfRadius.Metrics.spacing28)
                    .padding(.bottom, HfRadius.Metrics.spacing8)
            }
            footer
        }
        .frame(width: HfRadius.Metrics.newSessionSheetWidth)
        .frame(minHeight: HfRadius.Metrics.newSessionMinimumHeight,
               idealHeight: HfRadius.Metrics.newSessionIdealHeight, maxHeight: HfRadius.Metrics.newSessionMaximumHeight)
        .background(Color.cardFill)
        .onAppear {
            viewModel.didAppear()
            isPromptFocused = true
        }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            Text("New session").font(.hf(.title, weight: .semibold))
            Text("Start an agent on one of your repos. It runs in the background and shows up in the sidebar.")
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            sectionTitle("What should it do?")
            promptEditor
            HStack(spacing: HfRadius.Metrics.spacing12) {
                Text("Name").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                TextField("Optional — shown in the sidebar, e.g. MT-2477 iOS review", text: binding(\.name, { viewModel.didChangeName($0) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
            }
        }
    }

    private var promptEditor: some View {
        TextEditor(text: binding(\.message, { viewModel.didChangeMessage($0) }))
            .font(.hf(.body))
            // Bounded scope (§6.6): the task editor's own scroll view, if one exists; a quiet
            // no-op otherwise, with the shared field editor never targeted.
            .scrollChromeScope()
            .scrollContentBackground(.hidden)
            .focused($isPromptFocused)
            .padding(.horizontal, HfRadius.Metrics.spacing8)
            .padding(.vertical, HfRadius.Metrics.spacing8)
            .frame(height: HfRadius.Metrics.newSessionPromptEditorHeight)
            .background(RoundedRectangle(cornerRadius: HfRadius.card).fill(Color.windowBG))
            .overlay(alignment: .topLeading) {
                if viewModel.message.isEmpty {
                    Text("Describe the task, like you would to a colleague…")
                        .font(.hf(.body))
                        .foregroundStyle(Color.secondaryText)
                        .padding(.horizontal, HfRadius.Metrics.newSessionPromptPlaceholderInset)
                        .padding(.vertical, HfRadius.Metrics.spacing8)
                        .allowsHitTesting(false)
                }
            }
            // §6.6: the focus ring is a 1.5 pt accent stroke plus a 4 pt running-tint glow.
            .overlay(
                RoundedRectangle(cornerRadius: HfRadius.card)
                    .stroke(isPromptFocused ? Color.accentLink : Color.cardBorder,
                            lineWidth: isPromptFocused ? HfRadius.Metrics.newSessionPromptFocusBorderWidth : HfRadius.Metrics.hairlineStroke)
            )
            .shadow(color: isPromptFocused ? Color.runningBG : .clear, radius: HfRadius.Metrics.newSessionPromptFocusGlowRadius)
            .accessibilityLabel("What should it do?")
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            sectionTitle("Harness")
            AgentGrid(cards: viewModel.agentCards, onSelect: viewModel.didChangeBackend)
            ForEach(viewModel.qualificationCards) { card in
                HarnessQualificationCard(model: card.model, action: viewModel.didTapQualification)
            }
            if let note = viewModel.agentListUnavailableNote {
                Text(note).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            } else if let note = viewModel.agentNotFoundNote {
                Text(note).font(.hf(.caption)).foregroundStyle(Color.warningFG)
            }
        }
    }

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            sectionTitle("Repository")
            HStack(spacing: HfRadius.Metrics.spacing8) {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    Image(systemName: "folder").foregroundStyle(Color.secondaryText)
                    TextField("/path/to/repo", text: binding(\.repo, { viewModel.didChangeRepo($0) }))
                        .textFieldStyle(.plain)
                        .font(.hf(.secondary, design: .monospaced))
                        .accessibilityLabel("Repository path")
                }
                .padding(.horizontal, HfRadius.Metrics.spacing10)
                .frame(height: HfRadius.Metrics.segmentedHeight)
                .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.composerFill))
                .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
                Button("Choose…") { viewModel.didTapChooseDirectory() }
                    .buttonStyle(QuietButtonStyle())
            }
            RecentRepos(repos: viewModel.recentRepos, onSelect: viewModel.didTapRecentRepo)
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            sectionTitle("What can it change?")
            // Side-by-side radio cards: 2×2 at the default 760 sheet, wrapping to one column when
            // four cannot readably fit. The ONLY caption is the existing enforcement caveat.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: HfRadius.Metrics.newSessionAccessCardMinimumWidth),
                                         spacing: HfRadius.Metrics.spacing12)],
                      spacing: HfRadius.Metrics.spacing12) {
                ForEach(viewModel.accessOptions) { option in
                    AccessOptionRow(model: option) { viewModel.didChangeFreedom(option.id) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What can it change?")
            Text("How strictly this is enforced depends on the harness. The task's Technical info shows exactly what applied.")
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isAdvancedExpanded.toggle() }
            } label: {
                HStack(spacing: HfRadius.Metrics.spacing6) {
                    Image(systemName: "chevron.right")
                        .font(.hf(.caption, weight: .semibold))
                        .rotationEffect(.degrees(isAdvancedExpanded ? HfRadius.Metrics.newSessionDisclosureAngle : 0))
                    Text("Advanced — model, effort, turn limit").font(.hf(.secondary))
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

    private var approvalDescription: String {
        viewModel.callerApprovalError ?? viewModel.approvalNote ?? (viewModel.supportsCallerApprovals
            ? "Exact action once; requires uncapped repository write or publish access. Existing restrictions still apply."
            : "Unsupported or unmeasured for this harness.")
    }

    private var advancedFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: HfRadius.Metrics.spacing12, verticalSpacing: HfRadius.Metrics.spacing16) {
            if viewModel.showsEffort {
                GridRow {
                    Text("Reasoning effort").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                    Picker("Reasoning effort", selection: binding(\.effort, { viewModel.didChangeEffort($0) })) {
                        Text("Default").tag("")
                        ForEach(viewModel.effortOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: HfRadius.Metrics.newSessionAdvancedFieldWidth, alignment: .leading)
                }
            }
            if viewModel.showsModel {
                GridRow {
                    Text("Model").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                    ModelCombo(text: viewModel.model, choices: viewModel.modelChoices, onChange: { viewModel.didChangeModel($0) })
                }
            }
            if let note = viewModel.modelUnavailableNote {
                GridRow {
                    Text("Model").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                    Text(note).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                }
            }
            GridRow {
                Text("Caller approvals").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                VStack(alignment: .leading) {
                    Toggle("Ask before each eligible action", isOn: Binding(
                        get: { viewModel.callerApprovals }, set: { viewModel.didChangeCallerApprovals($0) }
                    ))
                        .disabled(!viewModel.supportsCallerApprovals)
                    Text(approvalDescription)
                        .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                }
            }
            if viewModel.showsTurnLimit {
                GridRow {
                    Text("Turn limit").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                        TextField("Empty uses the default", text: binding(\.turnLimit, { viewModel.didChangeTurnLimit($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: HfRadius.Metrics.newSessionAdvancedFieldWidth)
                            .accessibilityLabel("Turn limit")
                        if let error = viewModel.turnLimitError {
                            Text(error).font(.hf(.caption)).foregroundStyle(Color.failedRed)
                        }
                    }
                }
            }
        }
        .padding(.leading, HfRadius.Metrics.newSessionAdvancedLeadingInset)
    }

    private var footer: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            Rectangle().fill(Color.hairline).frame(height: HfRadius.Metrics.hairlineStroke)
            HStack(spacing: HfRadius.Metrics.spacing10) {
                Text("⌘↩ to start").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                Spacer()
                Button("Cancel") { viewModel.didTapCancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    viewModel.didTapStart()
                } label: {
                    Label(viewModel.isStarting ? "Starting…" : "Start session", systemImage: "play.fill")
                }
                .buttonStyle(MonitorButtonStyle(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canStart)
            }
            .padding(.horizontal, HfRadius.Metrics.spacing28)
            .padding(.top, HfRadius.Metrics.spacing12)
            .padding(.bottom, HfRadius.Metrics.spacing16)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.hf(.body, weight: .semibold))
    }

    private func binding(_ keyPath: KeyPath<VM, String>, _ set: @escaping @MainActor (String) -> Void) -> Binding<String> {
        Binding(get: { viewModel[keyPath: keyPath] }, set: { set($0) })
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

@MainActor
extension NewSessionViewModel {
    var callerApprovals: Bool { false }
    var supportsCallerApprovals: Bool { false }
    var callerApprovalError: String? { nil }
    var approvalNote: String? { nil }
    func didChangeCallerApprovals(_ value: Bool) {}
}

extension NewSessionViewModel {
    var qualificationCards: [QualificationCard] { [] }
    func didTapQualification() {}
}
