//
//  MenuBarRuntimeCardView.swift
//  MenuBarFeature
//

import HfUI
import SwiftUI

// MARK: - MenuBarRuntimeCardView

/// The not-ready block (`.hd-mb-block`): the subline, an optional strong title, the text, the failure line and Open Harflow.
/// It sits directly on the popover's glass, so its ink follows the same primary-text rule as the rest of the screen.
struct MenuBarRuntimeCardView: View {
    let card: MenuBarRuntimeCard
    let openHarflow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            Text(card.subline)
                .font(.hf(.secondary))
                .foregroundStyle(card.isFailed ? Color.failedRed : Color.primaryText)
            if let title = card.title {
                Text(title).font(.hf(.body, weight: .semibold)).foregroundStyle(Color.primaryText)
            }
            Text(card.text).font(.hf(.body)).foregroundStyle(Color.primaryText)
            if let failure = card.failureMessage {
                Text(failure)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
            }
            if card.offersOpenHarflow {
                Button("Open Harflow", action: openHarflow)
                    .buttonStyle(MonitorButtonStyle(.primary))
                    .accessibilityIdentifier("menu-bar-runtime-open")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-runtime-card")
    }
}

#if DEBUG
#Preview("Runtime card setup required") {
    MenuBarRuntimeCardView(card: .setupRequired, openHarflow: {}).frame(width: 348).padding()
}

#Preview("Runtime card preparing") {
    MenuBarRuntimeCardView(card: .preparing, openHarflow: {}).frame(width: 348).padding()
}

#Preview("Runtime card failed") {
    MenuBarRuntimeCardView(card: .failed(message: "Package verification failed. No replacement was activated."), openHarflow: {})
        .frame(width: 348)
.padding()
}
#endif
