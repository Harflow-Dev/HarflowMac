//
//  GeneralSettingsView.swift
//  SettingsFeature
//
//  General settings: managed runtime status, task-store recovery and behaviour toggles.
//  Runtime selection is managed by the application; there is no tool-directory control.
//

import Foundation
import HfCommon
import HfRepository
import HfUI
import SwiftUI

// MARK: - GeneralSettingsViewModel

/// View model protocol for the General settings tab.
@MainActor
protocol GeneralSettingsViewModel: ViewModel {

    var runtimeSetupState: RuntimeSetupState { get }
    var recoveryPresentation: StoreRecoveryPresentation { get }
    func didTapInstallRuntime()
    func didTapInspectStore()
    func didTapRequestRecovery()
    func didTapCancelRecovery()
    func didTapConfirmRecovery()
    func didTapRevealBackup()
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
    var notifyOnNeedsYou: Bool { get }

    func didAppear()
    func didDisappear()
    func didToggleOpenWindowOnStart(_ isOn: Bool)
    func didToggleNotifyOnFinish(_ isOn: Bool)
    func didToggleNotifyOnNeedsYou(_ isOn: Bool)
}

extension GeneralSettingsViewModel {
    var runtimeSetupState: RuntimeSetupState { .ready }
    var recoveryPresentation: StoreRecoveryPresentation { StoreRecoveryPresentation(state: .idle) }
    func didTapInstallRuntime() {}
    func didTapInspectStore() {}
    func didTapRequestRecovery() {}
    func didTapCancelRecovery() {}
    func didTapConfirmRecovery() {}
    func didTapRevealBackup() {}
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
            Section("Managed runtime") {
                Text(viewModel.runtimeSetupState.title)
                Text(viewModel.runtimeSetupState.detail).foregroundStyle(.secondary)
                if viewModel.runtimeSetupState.isBusy { ProgressView().controlSize(.small) }
                if let action = viewModel.runtimeSetupState.actionTitle {
                    Button(action) { viewModel.didTapInstallRuntime() }.accessibilityIdentifier("settings-runtime-action")
                }
            }
            Section("Task store") {
                StoreRecoveryPanel(model: viewModel.recoveryPresentation,
                                   inspect: viewModel.didTapInspectStore, request: viewModel.didTapRequestRecovery,
                                   cancel: viewModel.didTapCancelRecovery, confirm: viewModel.didTapConfirmRecovery,
                                   reveal: viewModel.didTapRevealBackup)
                    .disabled(!viewModel.runtimeSetupState.isReady)
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
                Toggle(
                    "Notify when a request needs you",
                    isOn: Binding(get: { viewModel.notifyOnNeedsYou }, set: { viewModel.didToggleNotifyOnNeedsYou($0) })
                )
            }
        }
        // Bounded scope (§6.7): the grouped Form's own native scroll view, when one exists —
        // a Form that creates none stays a quiet no-op, and the window's outer scrollers are
        // untouched.
        .scrollChromeScope()
        .formStyle(.grouped)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

}

#if DEBUG
#Preview("General - light") {
    GeneralSettingsView(GeneralSettingsViewModelMock()).preferredColorScheme(.light)
}

#Preview("General - dark") {
    GeneralSettingsView(GeneralSettingsViewModelMock()).preferredColorScheme(.dark)
}
#endif
