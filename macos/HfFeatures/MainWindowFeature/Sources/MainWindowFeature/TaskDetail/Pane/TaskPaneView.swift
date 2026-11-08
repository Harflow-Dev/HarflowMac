//
//  TaskPaneView.swift
//  MainWindowFeature
//
//  The standalone task screen's right pane (`aside.hd-pane`, HarflowDesign 17739e4): a 420 point column with a
//  head (tabs, spacer, close button) over the selected tab. `Changes` is reserved ahead of Artifacts and is not
//  drawn until it has a design. The pane is mounted only while open.
//

import HfUI
import MonitorCore
import SwiftUI

// MARK: - TaskPaneView

/// The pane for the standalone mount. In `.overlay` mode it carries the popover shadow and ring and sits over the
/// transcript column; in `.split` mode it sits beside it.
struct TaskPaneView<VM: TaskDetailViewModel>: View {
    let viewModel: VM
    let pane: TaskPaneController
    let presentation: TaskPaneController.Mode
    let focus: TaskPaneFocus

    var body: some View {
        let head = TaskScreenStyle.PaneHead.self
        VStack(spacing: 0) {
            header
            Rectangle().fill(head.borderColor.color).frame(height: head.bottomBorderWidth)
            tabBody
        }
        .frame(width: head.width)
        .frame(maxHeight: .infinity)
        .background(head.fill.color)
        .overlay(alignment: .leading) {
            Rectangle().fill(head.borderColor.color).frame(width: head.leadingBorderWidth)
        }
        .modifier(OverlayElevation(isOverlay: presentation == .overlay))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task details")
        .accessibilityAddTraits(presentation == .overlay ? .isModal : [])
    }

    private var header: some View {
        let head = TaskScreenStyle.PaneHead.self
        return HStack(spacing: head.gap) {
            HStack(spacing: TaskScreenStyle.PaneTab.gap) {
                ForEach(TaskPaneController.visibleTabs, id: \.self) { tab in
                    TaskPaneTabButton(title: Self.title(of: tab), isSelected: pane.selectedTab == tab) { pane.animated { pane.select(tab) } }
                }
            }
            Spacer(minLength: 0)
            Button { pane.animated { pane.close() } } label: {
                Image(systemName: "xmark")
.font(TaskScreenStyle.sans(size: Self.closeGlyphSize).weight(.medium))
                    .frame(width: Self.closeSize, height: Self.closeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TaskScreenStyle.PaneTab.color.color)
            .help("Close right pane")
            .accessibilityLabel("Close right pane")
        }
        .padding(.horizontal, head.paddingHorizontal)
        .frame(height: head.height)
    }

    @ViewBuilder private var tabBody: some View {
        switch pane.selectedTab {
        case .artifacts:
            ScrollView {
                TaskArtifactsView(members: viewModel.artifactMembers, load: { viewModel.didLoadArtifacts(taskID: $0) })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TaskScreenStyle.PaneBody.padding)
            }
        case .events, .changes:
            TaskEventsTabView(viewModel: viewModel, pane: pane, focus: focus)
        }
    }

    static func title(of tab: TaskPaneStateStore.Tab) -> String {
        switch tab {
        case .changes: "Changes"
        case .artifacts: "Artifacts"
        case .events: "Events"
        }
    }

    private static var closeSize: CGFloat { 26 }
    private static var closeGlyphSize: CGFloat { 12 }
}

// MARK: - TaskPaneTabButton

/// `.hd-tab`: 30 point high, 13 point medium, `surface-active` fill while selected.
private struct TaskPaneTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let tab = TaskScreenStyle.PaneTab.self
        Button(action: action) {
            Text(title)
                .font(TaskScreenStyle.sans(size: tab.fontSize).weight(tab.weight))
                .foregroundStyle((isSelected ? tab.activeColor : tab.color).color)
                .padding(.horizontal, tab.paddingHorizontal)
                .frame(height: tab.height)
                .background(RoundedRectangle(cornerRadius: tab.cornerRadius).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: tab.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        let tab = TaskScreenStyle.PaneTab.self
        if isSelected { return tab.activeFill.color }
        return isHovering ? tab.hoverFill.color : .clear
    }
}

// MARK: - OverlayElevation

/// The overlay pane's popover shadow and one point outer ring. The ring is a stroke centred half a point outside
/// the edge so it lies wholly outside the pane, as a CSS `0 0 0 1px` shadow does; `strokeBorder` would draw it inside.
private struct OverlayElevation: ViewModifier {
    let isOverlay: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let ring = TaskScreenStyle.PaneHead.overlayRing
        let isDark = colorScheme == .dark
        let ringOpacity = isOverlay ? (isDark ? ring.darkOpacity : ring.lightOpacity) : 0
        // One structure in both modes: only the ink changes, so crossing the split threshold never remounts the pane.
        return content
            .background {
                ForEach(Array(TaskScreenStyle.PaneHead.overlayShadow.enumerated()), id: \.offset) { _, layer in
                    Rectangle()
.fill(TaskScreenStyle.PaneHead.fill.color)
                        .shadow(color: Color.shadow.opacity(isOverlay ? (isDark ? layer.darkOpacity : layer.lightOpacity) : 0),
                                // CSS blur is the full blur diameter; SwiftUI's radius is half of it.
                                radius: layer.blur / 2, y: layer.offsetY)
                }
            }
            .overlay {
                Rectangle()
                    .inset(by: -ring.width / 2)
                    .stroke(Self.ink(isDark ? ring.darkInk : ring.lightInk).opacity(ringOpacity), lineWidth: ring.width)
                    .allowsHitTesting(false)
            }
    }

    private static func ink(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
