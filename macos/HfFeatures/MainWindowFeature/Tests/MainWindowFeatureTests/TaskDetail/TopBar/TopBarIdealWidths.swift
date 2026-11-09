//
//  TopBarIdealWidths.swift
//  MainWindowFeatureTests
//

import AppKit
import HfRepository
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI

// MARK: - TopBarIdealWidths

/// Independent measurements of each principal part's ideal width, taken from the same views in a separate hosting view,
/// and the production solver's prediction from them. The rendered principal is compared with this prediction, so a layout
/// that drifts from the approved rule (title first, meta shrinking to keep the title at 80, meta dropped under 60) fails.
@MainActor enum TopBarIdealWidths {

    private static func ideal(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    static func title(_ text: String) -> CGFloat {
        ideal(Text(text).font(.hf(.reading, weight: TaskScreenStyle.TopBar.titleWeight)).lineLimit(1).fixedSize())
    }

    static func meta(_ text: String) -> CGFloat {
        ideal(Text(text).font(.hf(.secondary)).lineLimit(1).fixedSize())
    }

    static func badge(_ model: TaskBadgeModel) -> CGFloat { ideal(TaskStatusBadge(model: model)) }

    /// The badge with its label truncated away, as the layout's over-budget case draws it.
    static func badgeMinimum(_ model: TaskBadgeModel) -> CGFloat {
        NSHostingController(rootView: TaskStatusBadge(model: model)).sizeThatFits(in: CGSize(width: 0, height: 1000)).width
    }

    static func status(_ view: AnyView) -> CGFloat { ideal(view) }

    /// The widest badge the product's mapping can produce, chosen by measurement among the mapped candidates.
    static func widestBadge() -> TaskBadgeModel {
        let hour = Date().addingTimeInterval(-3700)
        func evidence(_ status: TaskStatus, taken: Bool = false, snapshot: TaskStatus? = nil, exit: Int? = nil,
                      log: EventLogState? = nil, owner: String? = nil, duration: TimeInterval? = nil) -> TaskSnapshotEvidence {
            TaskSnapshotEvidence(status: status, takenOver: taken, snapshotStatus: snapshot, exitCode: exit, logState: log,
                                 ownerState: owner, settledDuration: duration)
        }
        let candidates: [TaskBadgeModel] = [
            .make(evidence: evidence(.running, taken: true), startedAt: hour),
            .make(evidence: evidence(.running, snapshot: .running, owner: "dead"), startedAt: hour),
            .make(evidence: evidence(.running, snapshot: .running, owner: "undecidable"), startedAt: hour),
            .make(evidence: evidence(.completed, snapshot: .completed), startedAt: nil),
            .make(evidence: evidence(.failed, snapshot: .failed, log: .incomplete), startedAt: nil),
            .make(evidence: evidence(.timedOut, duration: 3700), startedAt: nil),
            .make(evidence: evidence(.cancelled, taken: true, duration: 3700), startedAt: nil)
        ]
        return candidates.max { badge($0) < badge($1) } ?? candidates[0]
    }

    // MARK: Prediction

    /// What the production solver chooses from independently measured parts.
    struct Prediction {
        let cap: CGFloat
        let titleIdeal: CGFloat
        let metaIdeal: CGFloat?
        let solution: TopBarPrincipalLayout.Solution
        /// The ideal widths of the fixed parts in the order the solver was given them: badge, busy slot, status.
        let fixed: [CGFloat]
        let badgeMinimum: CGFloat
        /// Whether meta is eligible to show at all (not narrow, not pending, pane not carrying a supervision chip).
        let metaEligible: Bool

        /// Whether meta should be on screen: eligible and not dropped by the solver.
        var expectsMeta: Bool { metaEligible && solution.metaWidth != nil }
    }

    static func predict(content: TaskTopBarContent, band: TopBarWidthBand, statusView: AnyView) -> Prediction {
        let eligible = content.showsMeta(isNarrow: band.isNarrow)
        let titleIdeal = title(content.title)
        let metaIdeal = eligible ? meta(content.metaText) : nil
        let fixed = [badge(content.badge), TaskTopBarPrincipal.busySlotWidth, status(statusView)]
        let minimum = badgeMinimum(content.badge)
        let solution = TopBarPrincipalLayout.solve(titleIdeal: titleIdeal, metaIdeal: metaIdeal, fixed: fixed, cap: band.cap,
                                                   badgeIndex: 0, badgeMinimum: minimum)
        return Prediction(cap: band.cap, titleIdeal: titleIdeal, metaIdeal: metaIdeal, solution: solution, fixed: fixed,
                          badgeMinimum: minimum, metaEligible: eligible)
    }
}
