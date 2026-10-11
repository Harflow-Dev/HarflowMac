//
//  GeneralSettingsView.swift
//  SettingsFeature
//
//  Ported from the app target's `SettingsView.swift` (`GeneralSettings`). Behaviour is unchanged:
//  the directory field loads on appear and stays a local draft until commit, Apply (Return or the
//  inline button) trims whitespace before storing, Detect (Search again renamed, §4) clears the
//  override and refreshes the existing resolution, and the resolved tool paths update immediately
//  once the setting changes.
//

import Foundation
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
            Section("Command-line tools") {
                resolvedRow("polybridge-ctl", resolution: viewModel.ctlResolution)
                resolvedRow("polybridge-setup", resolution: viewModel.setupResolution)
                locationRow
                pathFootnote
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

    // MARK: - Private Views

    /// The Location field with its two existing actions: Return commits, the compact inline
    /// Apply button commits on click (a native component adaptation of the same action, kept for
    /// click-only accessibility), and Detect is Search again renamed — it clears the override and
    /// refreshes the existing resolution, never a new environment discovery.
    private var locationRow: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                TextField(
                    "Folder holding polybridge-ctl (blank = search)",
                    text: Binding(get: { viewModel.directoryField }, set: { viewModel.didChangeDirectoryField($0) })
                )
                .onSubmit { viewModel.didTapApply() }
                Button("Apply") { viewModel.didTapApply() }
                Button("Detect") { viewModel.didTapSearchAgain() }
            }
            Text("Searched: " + viewModel.searchedDirectoriesText)
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
                .textSelection(.enabled)
        }
    }

    /// The PATH footnote (§4): the short sentence plus an Environment details disclosure holding
    /// the original one — an in-screen collapse, no new navigation or backend action.
    private var pathFootnote: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            Text("Agents run with your login-shell PATH.")
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
            DisclosureGroup("Environment details") {
                Text("Everything the app runs gets your login-shell PATH, no PB_* variables, and PB_OPEN_MONITOR=0.")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.pb(.secondary))
        }
    }

    /// One resolved tool row: a status glyph, the tool's name, and the resolved FOLDER in
    /// monospaced secondary text — the full path rides the help tooltip instead of painting the
    /// whole path green.
    @ViewBuilder
    private func resolvedRow(_ tool: String, resolution: ToolResolution) -> some View {
        switch resolution {
        case .found(let path):
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Image(systemName: "checkmark.circle")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.doneGreen)
                    .accessibilityHidden(true)
                Text(tool).font(.pb(.body))
                Spacer(minLength: PbRadius.Metrics.spacing8)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.pb(.secondary, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(path)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tool) found")
            .accessibilityValue(path)
        case .notFound:
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Image(systemName: "xmark.circle")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.failedRed)
                    .accessibilityHidden(true)
                Text(tool).font(.pb(.body))
                Spacer(minLength: PbRadius.Metrics.spacing8)
                Text("not found").font(.pb(.secondary)).foregroundStyle(Color.failedRed)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tool) not found")
        }
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
