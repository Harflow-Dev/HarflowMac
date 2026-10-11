//
//  SettingsNavigationView.swift
//  SettingsFeature
//

import PbCommon
import PbUI
import PbUtilities
import SwiftUI

// MARK: - SettingsNavigationView

/// The Settings scene's root: a native `TabView` over General and Harnesses (the SDK's own
/// centered toolbar-tab appearance — no separate coordinator selection mirror), exactly as the old
/// `SettingsView`. The `ViewEvent` presentation context is applied once here — the scene root this
/// feature owns — so either tab's `publishDialog` renders correctly. Each tab's content stays in
/// a max-560 pt column, centred near the top; vertical overflow scrolls as before.
public struct SettingsNavigationView<Coordinator: SettingsNavigationCoordinator>: View {

    // MARK: - Properties

    @State private var coordinator: Coordinator

    // MARK: - Init

    /// Mounts the Settings subtree owned by this coordinator.
    public init(coordinator: Coordinator) {
        self._coordinator = State(initialValue: coordinator)
    }

    // MARK: - View Body

    /// Native General and Harnesses tabs sharing one presentation context.
    public var body: some View {
        TabView {
            tabContent(coordinator.buildGeneralSettingsView())
                .tabItem { Label("General", systemImage: "gearshape") }
            tabContent(coordinator.buildHarnessesView())
                .tabItem { Label("Harnesses", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: PbRadius.Metrics.settingsSceneWidth, height: PbRadius.Metrics.settingsSceneHeight)
        .withPresentationContext()
    }

    /// The content column (§6.7): max 560 pt, centred near the top. The native Form/List inside
    /// each tab keeps its own scrolling, so actual errors and rows overflow vertically as before.
    private func tabContent(_ view: AnyView) -> some View {
        view
            .frame(maxWidth: PbRadius.Metrics.settingsContentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#if DEBUG
/// A preview coordinator mock: the same two views the real coordinator builds, driven by the
/// feature's own preview-mock VMs — no production data invented.
@Observable
@MainActor
private final class SettingsNavigationCoordinatorMock: SettingsNavigationCoordinator {
    let parent: any Coordinator = DummyCoordinator()
    var path: [PathDestination] { [] }

    func handle(path _: any PathDestination) {}

    func start() -> AnyView {
        SettingsNavigationView(coordinator: self).eraseToAnyView()
    }

    func buildGeneralSettingsView() -> AnyView {
        GeneralSettingsView(GeneralSettingsViewModelMock()).eraseToAnyView()
    }

    func buildHarnessesView() -> AnyView {
        HarnessesView(HarnessesViewModelMock()).eraseToAnyView()
    }
}

#Preview("Settings - light") {
    SettingsNavigationView(coordinator: SettingsNavigationCoordinatorMock())
        .preferredColorScheme(.light)
}

#Preview("Settings - dark") {
    SettingsNavigationView(coordinator: SettingsNavigationCoordinatorMock())
        .preferredColorScheme(.dark)
}
#endif
