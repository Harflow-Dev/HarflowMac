import HfCommon
import HfRepository
import HfUI
import SwiftUI

// MARK: - SidebarNavigationRail

/// Approved m04-proposal/shell-collapsed, sharing the window's sidebar observation and appearance.
struct SidebarNavigationRail<VM: SidebarViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State var viewModel: VM
    let expand: @MainActor () -> Void

    init(_ viewModel: VM, expand: @escaping @MainActor () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.expand = expand
    }

    var body: some View {
        VStack(spacing: 12) {
            if let emblem = MainWindowEmblem.image {
                Image(nsImage: emblem).accessibilityLabel("Harflow")
            }
            Button(action: expand) {
                Label { Text("Expand sidebar") } icon: { SidebarNavigationIcon(.sidebar, size: 18) }
            }
                .accessibilityLabel("Expand sidebar")
                .accessibilityIdentifier("m04-expand-sidebar")
            Divider().padding(.horizontal, 8)
            navigation("New task", icon: .plus, destination: .newSession, action: viewModel.didTapNewSession)
            navigation("Needs you", icon: .hand, destination: .needsYou(itemID: nil)) {
                viewModel.didSelect(.needsYou(itemID: nil))
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.needsYouBadge.capsuleText != nil {
                    Circle().fill(Color.warningFG).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(viewModel.needsYouBadge.accessibilityLabel)
            navigation("Workflows", icon: .workflow, destination: .workflowLibrary) {
                viewModel.didSelect(.workflowLibrary)
            }
            navigation("Resources", icon: .gauge, destination: .resourceSlots) {
                viewModel.didSelect(.resourceSlots)
            }
            navigation("Statistics", icon: .chart, destination: .statistics) {
                viewModel.didSelect(.statistics)
            }
            Spacer(minLength: 8)
            Menu {
                Picker(selection: appearanceSelection) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.rawValue.capitalized).tag(appearance.rawValue)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label { Text("Change appearance") } icon: {
                    SidebarNavigationIcon(.appearance(viewModel.appAppearance), size: 16, isDecorative: false)
                }
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Change appearance")
            .accessibilityValue(viewModel.appAppearance.rawValue.capitalized)
            .help("Change appearance")
            SettingsLink { SidebarNavigationIcon(.settings, size: 16) }
                .accessibilityLabel("Settings")
                .help("Settings")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.hf(.body))
        .padding(.vertical, 16)
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(Color.cardFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation rail")
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    /// Native Picker selection supplies real menu-item state as well as the visible mark.
    private var appearanceSelection: Binding<String> {
        Binding(get: { viewModel.appAppearance.rawValue }, set: { value in
            guard let appearance = AppAppearance(rawValue: value) else { return }
            viewModel.didSelectAppearance(appearance)
        })
    }

    private func navigation(_ title: String, icon: SidebarNavigationArtwork, destination: MonitorDestination,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { SidebarNavigationIcon(icon, size: 18) }
        }
            .frame(width: 36, height: 32)
            .background(viewModel.selection == destination ? Color.accentLink.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .help(title)
            .accessibilityLabel(title)
            .disabled(!viewModel.runtimeSetupState.isReady)
    }
}

#if DEBUG
#Preview("Collapsed sidebar") {
    SidebarNavigationRail(SidebarViewModelMock(), expand: {}).frame(height: 620)
}
#endif
