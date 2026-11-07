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
    var composerState: ComposerState { get }
    var optionsLocked: Bool { get }
    var validationMessages: [String] { get }
    var canReviewSettings: Bool { get }
    var canReviewRecent: Bool { get }
    func didTapReviewSettings()
    func didTapReviewRecent()
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
    @Environment(\.viewEvent) var viewEvent
    @State var viewModel: VM
    @State private var optionsPresented: Bool
    @State private var repositoryPresented = false
    @State private var harnessPresented = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case prompt, options, firstOption }

    // These dimensions belong to the approved M04 composer, not shared component defaults.
    private enum Layout {
        static var maximumWidth: CGFloat { 720 }
        static var optionsWidth: CGFloat { 360 }
        static var optionsMaximumHeight: CGFloat { 400 }
        /// The smallest still-usable options popover when a short viewport leaves less room.
        static var optionsMinimumHeight: CGFloat { 208 }
    }

    init(_ viewModel: VM, optionsPresented: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        _optionsPresented = State(initialValue: optionsPresented)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                centeredGroup(for: geometry.size)
            }
        }
        .background(Color.windowBG)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    /// The whole approved group — heading, composer, outcome and help — centered in the scroll
    /// view's content area, capped at 720 wide and inset by one 24 point outer padding. The padded
    /// group keeps the viewport's own minimum height, so a short group centers vertically in the
    /// viewport exactly; when the group outgrows it, the content takes its natural height so the
    /// 24 point top padding scrolls with the heading instead of clipping it.
    private func centeredGroup(for size: CGSize) -> some View {
        VStack(spacing: HfRadius.Metrics.spacing20) {
            Text("What should we work on?")
                .font(.hf(.title, weight: .semibold))
                .frame(maxWidth: .infinity)
            composer(optionsHeight: optionsHeight(for: size))
            outcome
            Text("⌘↩ to start. Choices are remembered per repository in this window.")
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: Layout.maximumWidth)
        .padding(HfRadius.Metrics.spacing24)
        .frame(minHeight: max(0, size.height))
        .frame(maxWidth: .infinity)
        .background(ScrollChrome())
    }

    /// The + options popover adapts to the actual available viewport: capped at 400 and bounded
    /// by the window's own available height (its outer paddings), never a fixed top-padding
    /// threshold.
    private func optionsHeight(for size: CGSize) -> CGFloat {
        let available = size.height - 2 * HfRadius.Metrics.spacing24
        return min(Layout.optionsMaximumHeight, max(Layout.optionsMinimumHeight, available))
    }

    private func composer(optionsHeight: CGFloat) -> some View {
        VStack(spacing: HfRadius.Metrics.spacing8) {
            promptEditor
            composerControls(optionsHeight: optionsHeight)
        }
        .padding(EdgeInsets(top: HfRadius.Metrics.spacing12, leading: HfRadius.Metrics.spacing16,
                            bottom: HfRadius.Metrics.spacing8, trailing: HfRadius.Metrics.spacing12))
        .background(RoundedRectangle(cornerRadius: HfRadius.card).fill(Color.composerFill))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder))
    }

    private var promptEditor: some View {
        ComposerPromptEditor(text: binding(\.message, { viewModel.didChangeMessage($0) }), isLocked: viewModel.optionsLocked)
            .scrollChromeScope()
            .focused($focus, equals: .prompt)
            .overlay(alignment: .topLeading) {
                if viewModel.message.isEmpty {
                    Text("Describe the task.")
                        .font(.hf(.body))
                        .foregroundStyle(Color.secondaryText)
                        .padding(.top, ComposerSizing.verticalInset)
                        .padding(.leading, ComposerSizing.lineFragmentPadding)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Task prompt")
    }

    private func composerControls(optionsHeight: CGFloat) -> some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Button { optionsPresented.toggle() } label: {
                Image(systemName: "plus")
                    .overlay(alignment: .topTrailing) {
                        if customized {
                            Circle().fill(Color.accentLink).frame(width: HfRadius.Metrics.spacing4, height: HfRadius.Metrics.spacing4)
                        }
                    }
            }
            .focused($focus, equals: .options)
            .accessibilityLabel("More task options")
            .accessibilityValue(optionsPresented ? "expanded" : "collapsed")
            .accessibilityHint(customized ? "Customized options" : "Default options")
            .popover(isPresented: $optionsPresented, arrowEdge: .bottom) {
                options(height: optionsHeight)
                    .onAppear { focus = .firstOption }
                    .onExitCommand {
                        optionsPresented = false
                        focus = .options
                    }
            }
            Button { repositoryPresented.toggle() } label: {
                pill(repositoryTitle, icon: "folder")
            }
            .popover(isPresented: $repositoryPresented, arrowEdge: .bottom) { repositoryOptions }
            .disabled(viewModel.optionsLocked)
            Button { harnessPresented.toggle() } label: {
                pill(harnessTitle, icon: "cpu")
            }
            .popover(isPresented: $harnessPresented, arrowEdge: .bottom) { harnessOptions }
            .disabled(viewModel.optionsLocked)
            Menu {
                Picker(selection: binding(\.freedom, { viewModel.didChangeFreedom($0) })) {
                    if !viewModel.accessOptions.contains(where: { $0.id == viewModel.freedom }) {
                        Text("\(viewModel.freedom) — unavailable").tag(viewModel.freedom).disabled(true)
                    }
                    ForEach(viewModel.accessOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: { pill(accessTitle, icon: "shield") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(viewModel.optionsLocked)
            Spacer(minLength: HfRadius.Metrics.zero)
            Button(action: viewModel.didTapStart) {
                Image(systemName: "arrow.up")
                    .font(.hf(.body, weight: .semibold))
                    .frame(width: HfRadius.Metrics.segmentedHeight, height: HfRadius.Metrics.segmentedHeight)
            }
            .buttonStyle(ComposerSendButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.optionsLocked || !viewModel.canStart)
            .accessibilityLabel(viewModel.isStarting ? "Starting task" : "Start task")
        }
        .buttonStyle(.plain)
        .font(.hf(.secondary))
    }

    private func options(height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                Text("Task options").font(.hf(.body, weight: .semibold))
                TextField("Optional task title", text: binding(\.name, { viewModel.didChangeName($0) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Task title")
                    .focused($focus, equals: .firstOption)
                // Always retain editable requested values, including unsupported choices.
                HStack {
                    Text("Effort")
                    TextField("Default", text: binding(\.effort, { viewModel.didChangeEffort($0) }))
                        .accessibilityLabel("Reasoning effort")
                    Menu("Suggestions") {
                        Button("Default") { viewModel.didChangeEffort("") }
                        ForEach(viewModel.effortOptions, id: \.self) { value in
                            Button(value) { viewModel.didChangeEffort(value) }
                        }
                    }
                    .labelsHidden()
                }
                TextField("Turn limit — empty uses default", text: binding(\.turnLimit, { viewModel.didChangeTurnLimit($0) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Turn limit")
                Toggle("Caller approvals", isOn: Binding(get: { viewModel.callerApprovals }, set: { viewModel.didChangeCallerApprovals($0) }))
                    .accessibilityLabel("Caller approvals")
                Text(viewModel.callerApprovalError ?? viewModel.approvalNote ?? "Caller approvals depend on the selected harness and requested access.")
                    .foregroundStyle(Color.secondaryText)
                Text("Requested access: \(accessTitle). Enforcement depends on the harness; this is not an OS sandbox guarantee.")
                    .foregroundStyle(Color.secondaryText)
                ForEach(viewModel.qualificationCards) { card in
                    HarnessQualificationCard(model: card.model, action: viewModel.didTapQualification)
                }
            }
            .font(.hf(.secondary))
            .padding(HfRadius.Metrics.spacing16)
            .background(ScrollChrome())
        }
        .frame(width: Layout.optionsWidth, height: height)
        .disabled(viewModel.optionsLocked)
        // Stable identity for the actual options scroll view — hosted tests measure this exact
        // owned scroll surface, never the native popover bubble chrome around it.
        .accessibilityIdentifier("new-session-options-scroll")
        .accessibilityLabel("Task options")
    }

    private var repositoryOptions: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            Text("Repository").font(.hf(.body, weight: .semibold))
            TextField("/path/to/repo", text: binding(\.repo, { viewModel.didChangeRepo($0) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Repository path")
            Button("Choose folder…", action: viewModel.didTapChooseDirectory)
            RecentRepos(repos: viewModel.recentRepos, onSelect: viewModel.didTapRecentRepo)
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(width: Layout.optionsWidth)
        .disabled(viewModel.optionsLocked)
    }

    private var harnessOptions: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            Picker("Harness", selection: binding(\.backend, { viewModel.didChangeBackend($0) })) {
                if !viewModel.agentCards.contains(where: { $0.id == viewModel.backend }) {
                    Text("\(viewModel.backend) — unavailable").tag(viewModel.backend)
                }
                ForEach(viewModel.agentCards) { card in
                    Text(card.name + (card.isNotInstalled ? " — not installed" : "")).tag(card.id)
                }
            }
            ModelCombo(text: viewModel.model, choices: viewModel.modelChoices, onChange: { viewModel.didChangeModel($0) })
            Button("Use default model") { viewModel.didChangeModel("") }
            if let note = viewModel.modelUnavailableNote { Text(note) }
            if let note = viewModel.agentNotFoundNote { Text(note) }
            if let note = viewModel.agentListUnavailableNote { Text(note) }
        }
        .font(.hf(.secondary))
        .padding(HfRadius.Metrics.spacing16)
        .frame(width: Layout.optionsWidth)
        .disabled(viewModel.optionsLocked)
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if viewModel.qualificationCards.isEmpty {
                Text("Harness qualification is not available yet.")
                    .foregroundStyle(Color.secondaryText)
            }
            ForEach(viewModel.qualificationCards) { card in
                Text("Harness qualification: \(card.model.state.title). \(card.model.message)")
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("composer-qualification-\(card.id)")
            }
            if viewModel.isStarting { ProgressView("Starting task…") }
            if viewModel.composerState == .unknown {
                Text("The start outcome is unknown. Review Recent work before starting another task.")
            }
            if viewModel.composerState == .created { Text("Task created.") }
            if let error = viewModel.errorText { Text(error).foregroundStyle(Color.failedRed) }
            ForEach(viewModel.validationMessages, id: \.self) { Text($0).foregroundStyle(Color.warningFG) }
            if viewModel.canReviewSettings {
                Button("Review settings") {
                    viewModel.didTapReviewSettings()
                    optionsPresented = true
                }
            }
            if viewModel.canReviewRecent { Button("Review Recent work", action: viewModel.didTapReviewRecent) }
        }
        .font(.hf(.secondary))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customized: Bool {
        !viewModel.name.isEmpty || !viewModel.effort.isEmpty || !viewModel.turnLimit.isEmpty || viewModel.callerApprovals
    }

    private var repositoryTitle: String {
        viewModel.repo.isEmpty ? "Choose repository" : (viewModel.repo as NSString).lastPathComponent
    }

    private var harnessTitle: String {
        let name = viewModel.agentCards.first(where: { $0.id == viewModel.backend })?.name ?? "\(viewModel.backend) — unavailable"
        return name + " · " + (viewModel.model.isEmpty ? "Default" : viewModel.model)
    }

    private var accessTitle: String {
        viewModel.accessOptions.first(where: { $0.id == viewModel.freedom })?.title ?? viewModel.freedom
    }

    private func pill(_ title: String, icon: String) -> some View {
        HStack(spacing: HfRadius.Metrics.spacing6) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.hf(.caption))
        }
        .padding(.horizontal, HfRadius.Metrics.spacing8)
        .padding(.vertical, HfRadius.Metrics.spacing6)
        .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
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
