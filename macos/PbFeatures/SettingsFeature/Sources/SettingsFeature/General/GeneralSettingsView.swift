//
//  GeneralSettingsView.swift
//  SettingsFeature
//
//  Ported from the app target's `SettingsView.swift` (`GeneralSettings`). Behaviour is unchanged:
//  the directory field loads on appear, Apply trims whitespace before storing, "Search again"
//  clears the override, and the resolved tool paths update immediately once the setting changes.
//

import PbCommon
import PbUI
import SwiftUI

// MARK: - ToolResolution

/// Whether a required binary (`polybridge-ctl`/`polybridge-setup`) was found, and where.
public enum ToolResolution: Equatable, Sendable {
    case found(path: String)
    case notFound
}

// MARK: - GeneralSettingsViewModel

/// View model protocol for the General settings tab.
@MainActor
protocol GeneralSettingsViewModel: ViewModel {
    
    /// The text field's live value — loaded from the committed setting on `didAppear`, then edited
    /// locally until `didTapApply`/`didTapSearchAgain` commits it. Never overwritten by a live
    /// settings update from elsewhere, matching the old `SettingsView`'s local `@State`.
    var directoryField: String { get }
    var searchedDirectoriesText: String { get }
    var ctlResolution: ToolResolution { get }
    var setupResolution: ToolResolution { get }
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
    
    func didAppear()
    func didDisappear()
    func didChangeDirectoryField(_ text: String)
    func didTapApply()
    func didTapSearchAgain()
    func didToggleOpenWindowOnStart(_ isOn: Bool)
    func didToggleNotifyOnFinish(_ isOn: Bool)
}

// MARK: - GeneralSettingsView

struct GeneralSettingsView<VM: GeneralSettingsViewModel>: View {
    
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
        Form {
            Section("polybridge tools") {
                TextField(
                    "Folder holding polybridge-ctl (blank = search)",
                    text: Binding(get: { viewModel.directoryField }, set: { viewModel.didChangeDirectoryField($0) })
                )
                .onSubmit { viewModel.didTapApply() }
                HStack {
                    Button("Apply") { viewModel.didTapApply() }
                    Button("Search again") { viewModel.didTapSearchAgain() }
                }
                Text("Searched: " + viewModel.searchedDirectoriesText).font(.system(size: 11)).foregroundStyle(.secondary)
                resolvedRow("polybridge-ctl", resolution: viewModel.ctlResolution)
                resolvedRow("polybridge-setup", resolution: viewModel.setupResolution)
                Text("Everything the app runs gets your login-shell PATH, no PB_* variables, and PB_OPEN_MONITOR=0.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle(
                    "Open the window when a task starts",
                    isOn: Binding(get: { viewModel.openWindowOnStart }, set: { viewModel.didToggleOpenWindowOnStart($0) })
                )
                Toggle(
                    "Notify when a task finishes",
                    isOn: Binding(get: { viewModel.notifyOnFinish }, set: { viewModel.didToggleNotifyOnFinish($0) })
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
    
    // MARK: - Private Views
    
    @ViewBuilder
    private func resolvedRow(_ tool: String, resolution: ToolResolution) -> some View {
        switch resolution {
        case .found(let path):
            Label("\(tool): \(path)", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Color.doneGreen)
        case .notFound:
            Label("\(tool): not found", systemImage: "xmark.circle").font(.system(size: 11)).foregroundStyle(Color.failedRed)
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView(GeneralSettingsViewModelMock())
}
#endif
