//
//  GeneralSettingsView.swift
//  SettingsFeature
//
//  General settings for application behavior and managed runtime availability.
//  Runtime selection is managed by the application.
//

import Foundation
import HfCommon
import HfUI
import SwiftUI

// MARK: - ToolResolution

/// Whether a required binary (`harflow-ctl`/`harflow-setup`) was found, and where.
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
    var runtimeStatus: String { get }
    var runtimeCanRetry: Bool { get }
    func didTapRetryRuntime()

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
            Section("Managed runtime") {
                Text(viewModel.runtimeStatus)
                if viewModel.runtimeCanRetry {
                    Button("Try again") { viewModel.didTapRetryRuntime() }
                }
                Text("The app prepares its paired runtime automatically. MCP registrations are managed in Harnesses.")
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

/// Both tools missing: the not-found glyph treatment, still no invented values.
#Preview("General, tools missing - light") {
    GeneralSettingsView(GeneralSettingsViewModelMock(ctlResolution: .notFound, setupResolution: .notFound))
        .preferredColorScheme(.light)
}

#Preview("General, tools missing - dark") {
    GeneralSettingsView(GeneralSettingsViewModelMock(ctlResolution: .notFound, setupResolution: .notFound))
        .preferredColorScheme(.dark)
}
#endif
