//
//  BackendTabRow.swift
//  MainWindowFeature
//
//  The Sidebar's backend filter (Monitor piece 6, Review round 1 item 4): a horizontally scrollable
//  row of capsule tabs, never a segmented `Picker`. Keyboard navigation and focus are scoped to this
//  row alone via its own `.focusable()`/`.onMoveCommand` — the same mechanism `SidebarVM`'s tree
//  ←/→ already uses on the `List` itself, so neither one steals the other's arrow keys, and neither
//  steals the search field's. Which tab is *selected* vs. *focused* (and the arrow-key cycling logic
//  itself) is owned by `SidebarVM` — see `didFocusBackendTab(_:)`/`didPressBackendTabArrow(_:)`/
//  `didPressBackendTabConfirm()` — so it is unit-tested there; this view only renders the result and
//  forwards raw key/tap events.
//

import PbUI
import SwiftUI

// MARK: - BackendTabRow

struct BackendTabRow: View {
    let tabs: [BackendTab]
    let selectedID: String
    let focusedID: String
    let onSelect: (String) -> Void
    let onArrow: (MoveCommandDirection) -> Void
    let onConfirm: () -> Void

    @FocusState private var isRowFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        BackendTabCapsule(tab: tab, isSelected: tab.id == selectedID, isFocused: isRowFocused && tab.id == focusedID)
                            .id(tab.id)
                            .onTapGesture { onSelect(tab.id) }
                    }
                }
                // Room for the focus ring, which sits just outside the capsule.
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .focusable()
            .focused($isRowFocused)
            // The row draws its own focus ring on the focused capsule; the system one is a
            // rectangle around the whole scroll view.
            .focusEffectDisabled()
            .onMoveCommand { onArrow($0) }
            .onKeyPress(.space) { onConfirm(); return .handled }
            .onKeyPress(.return) { onConfirm(); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Backend filter")
            .onChange(of: selectedID) { _, newValue in scrollTo(newValue, proxy: proxy) }
            .onChange(of: focusedID) { _, newValue in scrollTo(newValue, proxy: proxy) }
        }
    }

    private func scrollTo(_ id: String, proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }
}

// MARK: - BackendTabCapsule

private struct BackendTabCapsule: View {
    let tab: BackendTab
    let isSelected: Bool
    let isFocused: Bool

    private var title: String { tab.id == "all" ? "All" : tab.id }

    private var foreground: Color {
        if isSelected { return tab.isNotFound ? Color.white.opacity(0.8) : .white }
        return tab.isNotFound ? Color.secondary.opacity(0.6) : .primary
    }

    var body: some View {
        Text(title)
            .font(.pb(.secondary, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Color.accentLink : Color.neutralFill))
            // Only while the row itself has keyboard focus, and on the selected tab too.
            .overlay(Capsule().stroke(isFocused ? Color.accentLink : .clear, lineWidth: 2).padding(-3))
            .contentShape(Capsule())
            .help(tab.isNotFound ? "\(title) wasn't found on your PATH" : "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityValue(tab.isNotFound ? "not found on PATH" : "")
    }
}

#if DEBUG
#Preview {
    BackendTabRow(
        tabs: [.all, BackendTab(id: "claude", isNotFound: false), BackendTab(id: "codex", isNotFound: true), BackendTab(id: "vibe", isNotFound: false)],
        selectedID: "claude", focusedID: "claude", onSelect: { _ in }, onArrow: { _ in }, onConfirm: {}
    )
    .frame(width: 280)
    .padding()
}
#endif
