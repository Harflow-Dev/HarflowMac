//
//  NewSessionView.swift
//  MainWindowFeature
//
//  Ported from the app target's `MainView.swift`'s `NewSessionSheet`. Behaviour is unchanged:
//  defaults are claude/interactive/read_only with an empty repo/message; interactive disables the
//  message field and ignores freedom; headless needs a non-blank message; the repo path is
//  validated by the VM (`NewSessionUseCase.resolvedRepoPath`); success dismisses the sheet, failure
//  stays inline.
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
    var interactive: Bool { get }
    var freedom: String { get }
    var message: String { get }
    var errorText: String? { get }
    var isStarting: Bool { get }
    var isMessageFieldDisabled: Bool { get }
    var canStart: Bool { get }
    
    func didAppear()
    func didDisappear()
    func didChangeBackend(_ value: String)
    func didChangeRepo(_ value: String)
    func didChangeInteractive(_ value: Bool)
    func didChangeFreedom(_ value: String)
    func didChangeMessage(_ value: String)
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
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New session").font(.system(size: 17, weight: .semibold))
                Text("Start an agent from the app. A headless task shows up in the sidebar like any other task.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Agent")
                Picker("Agent", selection: Binding(get: { viewModel.backend }, set: { viewModel.didChangeBackend($0) })) {
                    ForEach(BackendStyle.known, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Repository")
                HStack {
                    TextField("/path/to/repo", text: Binding(get: { viewModel.repo }, set: { viewModel.didChangeRepo($0) })).textFieldStyle(.roundedBorder)
                    Button("Choose…") { viewModel.didTapChooseDirectory() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "How to run it")
                Picker("Mode", selection: Binding(get: { viewModel.interactive }, set: { viewModel.didChangeInteractive($0) })) {
                    VStack(alignment: .leading) {
                        Text("Interactive terminal")
                        Text("Opens a terminal here running \(viewModel.backend) in the repo, exactly as if you ran it yourself — "
                             + "under your own configuration and permissions, not a polybridge freedom level.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }.tag(true)
                    VStack(alignment: .leading) {
                        Text("Headless task")
                        Text("Runs through polybridge with a freedom level, shown on the timeline. You can message it (claude) or take over later.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }.tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !viewModel.interactive {
                    Picker("Freedom", selection: Binding(get: { viewModel.freedom }, set: { viewModel.didChangeFreedom($0) })) {
                        ForEach(["read_only", "write_in_repo", "publish", "unrestricted"], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 280)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: viewModel.interactive ? "First message (type it in the terminal)" : "First message")
                TextEditor(text: Binding(get: { viewModel.message }, set: { viewModel.didChangeMessage($0) }))
                    .font(.system(size: 12))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                    .disabled(viewModel.isMessageFieldDisabled)
                    .opacity(viewModel.isMessageFieldDisabled ? 0.5 : 1)
            }
            if let errorText = viewModel.errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(Color.failedRed).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.didTapCancel() }.keyboardShortcut(.cancelAction)
                Button(viewModel.isStarting ? "Starting…" : "Start session") { viewModel.didTapStart() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
#Preview {
    NewSessionView(NewSessionViewModelMock())
}
#endif
