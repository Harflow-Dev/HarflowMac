//
//  SettingsNavigationView.swift
//  SettingsFeature
//

import PbUI
import SwiftUI

/// The Settings scene's root: a `TabView` over General and Harnesses, exactly as the old
/// `SettingsView`. The `ViewEvent` presentation context is applied once here — the scene root this
/// feature owns — so either tab's `publishDialog` renders correctly.
public struct SettingsNavigationView<Coordinator: SettingsNavigationCoordinator>: View {
    
    // MARK: - Properties
    
    @State private var coordinator: Coordinator
    
    // MARK: - Init
    
    public init(coordinator: Coordinator) {
        self._coordinator = State(initialValue: coordinator)
    }
    
    // MARK: - View Body
    
    public var body: some View {
        TabView {
            coordinator.buildGeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            coordinator.buildHarnessesView().tabItem { Label("Harnesses", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 620, height: 460)
        .withPresentationContext()
    }
}
