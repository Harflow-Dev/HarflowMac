//
//  TaskStatusBadge.swift
//  MainWindowFeature
//
//  The standalone top bar's status badge, drawn from `TaskBadgeModel` with the M05 badge metrics. HfUI's
//  `StatusBadge` is unchanged and still serves every other surface. Design reference: HarflowDesign 17739e4,
//  `bundle.css` `.hd-badge` and `m05-proposal.css` `.hd-m05-badge--neutral`.
//

import HfUI
import SwiftUI

// MARK: - TaskStatusBadge

/// A 22 point capsule: indicator, words and, when the model has one, a clock. A live clock ticks inside its own
/// child view, so only that child re-evaluates each second. The clock uses monospaced digits, a recorded
/// deviation from the proportional digits of the pin.
struct TaskStatusBadge: View {
    let model: TaskBadgeModel

    private typealias Metrics = TaskScreenStyle.Badge

    var body: some View {
        HStack(spacing: Metrics.gap) {
            indicator
            Text(model.label).truncationMode(.tail)
            clock
            if let suffix = model.suffix { Text(suffix).fixedSize() }
        }
        .font(.hf(.secondary, weight: Metrics.weight))
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(pair.foreground.color)
        .padding(.horizontal, model.tone == .plain ? Metrics.plainPadding : Metrics.paddingHorizontal)
        .frame(height: model.tone == .plain ? nil : Metrics.height)
        .background(Capsule().fill(model.tone == .plain ? Color.clear : pair.background.color))
        .modifier(BadgeAccessibility(model: model, fixedClockText: fixedClockText))
    }

    @ViewBuilder private var indicator: some View {
        switch model.icon {
        case .spinner:
            RunningSpinner(size: Metrics.spinSize, tint: pair.foreground.color).accessibilityHidden(true)
        case let .symbol(name):
            Image(systemName: name).font(.hf(.secondary)).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var clock: some View {
        switch model.clock {
        case .none: EmptyView()
        case let .fixed(seconds): Text(Format.clock(seconds)).monospacedDigit().fixedSize()
        case let .live(start): LiveBadgeClock(start: start)
        }
    }

    private var fixedClockText: String? {
        if case let .fixed(seconds) = model.clock { Format.clock(seconds) } else { nil }
    }

    private var pair: TaskScreenStyle.ColorPair {
        switch model.tone {
        case .running: Metrics.running
        case .done: Metrics.done
        case .failed: Metrics.failed
        case .attention: Metrics.attention
        case .warning: Metrics.warning
        case .neutral: Metrics.neutral
        case .plain: Metrics.base
        }
    }
}

// MARK: - BadgeAccessibility

/// A fixed badge is one element with its complete label. A live badge combines its children, so VoiceOver reads the
/// clock child's current text (its elapsed time) when focused, with no announcement per tick and the clock's
/// isolation intact.
private struct BadgeAccessibility: ViewModifier {
    let model: TaskBadgeModel
    let fixedClockText: String?

    @ViewBuilder func body(content: Content) -> some View {
        if case .live = model.clock {
            content.accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityText(clock: fixedClockText))
        }
    }
}

// MARK: - LiveBadgeClock

/// The running clock. Once a run is close to an hour old the clock reserves the width of an hours reading, so
/// crossing the hour does not change the badge's width.
private struct LiveBadgeClock: View {
    let start: Date

    /// Elapsed seconds from which the hours width is reserved.
    private static let reserveFrom: TimeInterval = 3000

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            ZStack(alignment: .leading) {
                if elapsed >= Self.reserveFrom { Text("0:00:00").hidden() }
                Text(Format.clock(elapsed))
            }
            .monospacedDigit()
            .fixedSize()
        }
    }
}
