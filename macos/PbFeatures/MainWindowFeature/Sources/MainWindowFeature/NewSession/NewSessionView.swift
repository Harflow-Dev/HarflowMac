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
    var errorText: String? { get }
    var isStarting: Bool { get }
    var canStart: Bool { get }

    func didAppear()
    func didDisappear()
    func didChangeBackend(_ value: String)
    func didChangeRepo(_ value: String)
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
                Text("New session").font(.pb(.title, weight: .semibold))
                Text("Start an agent from the app. A headless task shows up in the sidebar like any other task.")
                    .font(.pb(.body))
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
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Freedom")
                Picker("Freedom", selection: Binding(get: { viewModel.freedom }, set: { viewModel.didChangeFreedom($0) })) {
                    ForEach(["read_only", "write_in_repo", "publish", "unrestricted"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 280, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "First message")
                TextEditor(text: Binding(get: { viewModel.message }, set: { viewModel.didChangeMessage($0) }))
                    .font(.pb(.body))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
            }
            if let errorText = viewModel.errorText {
                Text(errorText).font(.pb(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled)
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
