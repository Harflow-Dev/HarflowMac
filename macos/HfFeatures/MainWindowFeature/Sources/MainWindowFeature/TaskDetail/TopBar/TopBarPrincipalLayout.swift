//
//  TopBarPrincipalLayout.swift
//  MainWindowFeature
//
//  The window toolbar never truncates its principal item; it moves other items into the overflow menu instead.
//  The principal content therefore lays itself out inside a cap, with a pure width solver: the title truncates
//  first, then meta, and meta is dropped rather than drawn as a sliver. Design reference: HarflowDesign 17739e4,
//  `m05-proposal.css` `.hd-m05-bar__center`.
//

import AppKit
import Observation
import SwiftUI

// MARK: - TopBarWidthBand

/// The window width band the shell maps its width to. Only a band crossing re-evaluates the shell.
enum TopBarWidthBand: Equatable, Sendable {
    /// Under 1100: chips shrink to icons and meta is hidden.
    case narrow
    /// 1100 to 1279.
    case compact
    /// 1280 to 1599.
    case regular
    /// 1600 and over.
    case wide

    /// The window width below which the top bar is narrow, the pin's frame rule.
    static let narrowThreshold: CGFloat = 1100

    /// The band for a window width.
    init(width: CGFloat) {
        switch width {
        case ..<1100: self = .narrow
        case ..<1280: self = .compact
        case ..<1600: self = .regular
        default: self = .wide
        }
    }

    var isNarrow: Bool { self == .narrow }

    /// The principal item's maximum width, including the connection status.
    var cap: CGFloat {
        switch self {
        case .narrow, .compact: 360
        case .regular: 440
        case .wide: 560
        }
    }
}

// MARK: - TopBarLayoutState

/// The window's width band as observable state, held by the shell but never read by its body: a band crossing
/// re-evaluates only the readers (the principal and the task toolbar's chips), never the shell or the detail
/// builder. Until the first measurement the band reads as `.regular`, so a window never starts narrow, and a first
/// measurement that equals it is not a crossing.
@MainActor
@Observable
final class TopBarLayoutState {
    /// The band to draw with; written only when it changes.
    private(set) var effectiveBand = TopBarWidthBand.regular
    /// The last measured band, `nil` before the first measurement.
    @ObservationIgnored private(set) var measuredBand: TopBarWidthBand?
    /// Whether the band is narrow; written only when it changes, so a task view reading it is not re-evaluated by
    /// a crossing between the wider bands. Only the principal reads `effectiveBand`.
    private(set) var isNarrow = false
    /// The detail column's width, `nil` before the first measurement; read only by the principal, for a group's
    /// width budget (`GroupTopBarBudget`). Written only when it changes.
    private(set) var detailWidth: CGFloat?
    /// The window's content width, `nil` before the first measurement. The principal is centred in the window, so a
    /// group's budget is also bounded by what fits beside the trailing buttons on both sides of the centre.
    private(set) var windowWidth: CGFloat?

    /// Records the detail column's measured width.
    func setDetailWidth(_ width: CGFloat) {
        if detailWidth != width { detailWidth = width }
    }

    /// Records the window's measured width.
    func setWindowWidth(_ width: CGFloat) {
        if windowWidth != width { windowWidth = width }
    }

    /// Records a measurement.
    func setBand(_ band: TopBarWidthBand) {
        measuredBand = band
        if effectiveBand != band { effectiveBand = band }
        if isNarrow != band.isNarrow { isNarrow = band.isNarrow }
    }
}

extension EnvironmentValues {
    /// The shell's layout state; `nil` outside the window shell, which reads as not narrow.
    @Entry var topBarLayout: TopBarLayoutState?
}

// MARK: - TopBarLayoutProbe

/// Carries the solver's explicit meta decision from the layout pass to the view that hides a dropped meta from
/// accessibility, so the decision never depends on how a Text sizes itself at a zero proposal.
@MainActor
final class TopBarLayoutProbe {
    /// Whether a layout pass has run.
    private(set) var hasSolved = false
    /// The solver's `metaDropped` for the latest pass.
    private(set) var metaDropped = false

    /// Records a pass.
    func record(metaDropped: Bool) {
        hasSolved = true
        self.metaDropped = metaDropped
    }

    /// Meta is hidden until the first pass, and whenever the solver dropped it.
    var hidesMeta: Bool { !hasSolved || metaDropped }
}

// MARK: - TopBarPrincipalLayout

/// Places title, badge, busy slot, meta and connection status in a row no wider than `cap`.
struct TopBarPrincipalLayout: Layout {

    /// What a subview is, set with `topBarRole(_:)`.
    enum Role: Hashable {
        case title, badge, busy, meta, status
    }

    struct RoleKey: LayoutValueKey {
        static let defaultValue = Role.status
    }

    /// The widths the solver chose.
    struct Solution: Equatable {
        let titleWidth: CGFloat
        /// `nil` when there is no meta, or when it was dropped.
        let metaWidth: CGFloat?
        let metaDropped: Bool
        /// The badge's truncated width when the fixed parts leave too little room for the title floor; `nil` keeps
        /// its ideal width.
        let badgeWidth: CGFloat?
    }

    /// The title never goes below this while it has room to start with (the pin's `min-width: 80px`).
    static let titleFloor = TaskScreenStyle.TopBar.titleMinWidth
    /// Meta narrower than this is dropped instead of drawn as a sliver. It applies only when the parts are truncated.
    static let metaFloor: CGFloat = 60
    /// Meta keeps at least this share of what the title and meta divide between them.
    static let metaShare: CGFloat = 0.45
    static let spacing = TaskScreenStyle.TopBar.groupGap

    let cap: CGFloat
    /// Receives the solver's result for the current pass; `nil` outside the principal.
    var probe: TopBarLayoutProbe?
    /// A group's own title floor; `nil` keeps the task's.
    var titleFloor: CGFloat?
    /// `false` for a group: the meta is whole or dropped.
    var metaMayTruncate = true

    /// The pure solver. `fixed` are the ideal widths of the parts that keep them (badge, busy slot, status);
    /// `badgeIndex` names the badge among them.
    ///
    /// 1. If every part's ideal width fits the cap, every part takes it (meta too, even under 60).
    /// 2. Otherwise the title truncates first: meta gets `min(ideal, max(remaining - titleIdeal, 45% of remaining))`
    ///    and shrinks only as far as needed to keep the title at 80 or more.
    /// 3. Meta is then dropped only if its allotted width is below both its ideal width and 60 points.
    /// 4. If the fixed parts plus the title floor exceed the cap, meta is dropped, the badge truncates to
    ///    `cap - other fixed parts - gaps - 80` (never below `badgeMinimum`), and if that is not enough the title takes what is left, below 80.
    ///    The total never exceeds the cap unless the non-badge fixed parts alone do.
    ///
    /// A group's content passes `metaMayTruncate: false` and its own `titleFloor`: its meta is then whole or dropped
    /// (never shortened), and shown only while the title keeps at least its floor. Task content keeps the defaults.
    nonisolated static func solve(titleIdeal: CGFloat, metaIdeal: CGFloat?, fixed: [CGFloat], cap: CGFloat,
                                  badgeIndex: Int? = nil, badgeMinimum: CGFloat = 0,
                                  titleFloor customFloor: CGFloat? = nil, metaMayTruncate: Bool = true) -> Solution {
        let fixedWidth = fixed.reduce(0, +)
        func remaining(withMeta: Bool) -> CGFloat {
            let parts = fixed.count + 1 + (withMeta ? 1 : 0)
            return cap - fixedWidth - spacing * CGFloat(parts - 1)
        }
        let floor = min(titleIdeal, customFloor ?? titleFloor)
        let withMeta = remaining(withMeta: metaIdeal != nil)
        if let metaIdeal, titleIdeal + metaIdeal <= withMeta {
            return Solution(titleWidth: titleIdeal, metaWidth: metaIdeal, metaDropped: false, badgeWidth: nil)
        }
        let alone = remaining(withMeta: false)
        if metaIdeal == nil, titleIdeal <= alone {
            return Solution(titleWidth: titleIdeal, metaWidth: nil, metaDropped: false, badgeWidth: nil)
        }
        if !metaMayTruncate, let metaIdeal {
            let titleRoom = withMeta - metaIdeal
            if titleRoom >= floor { return Solution(titleWidth: min(titleIdeal, titleRoom), metaWidth: metaIdeal, metaDropped: false, badgeWidth: nil) }
            return Solution(titleWidth: max(0, min(titleIdeal, alone)), metaWidth: nil, metaDropped: true, badgeWidth: nil)
        }
        if alone < floor {
            return overBudget(titleIdeal: titleIdeal, dropsMeta: metaIdeal != nil, fixed: fixed, cap: cap,
                              badge: badgeIndex.map { ($0, badgeMinimum) })
        }
        guard let metaIdeal else {
            return Solution(titleWidth: min(titleIdeal, alone), metaWidth: nil, metaDropped: false, badgeWidth: nil)
        }
        var meta = min(metaIdeal, max(withMeta - titleIdeal, metaShare * withMeta))
        var title = min(titleIdeal, withMeta - meta)
        if title < floor {
            meta = max(0, withMeta - floor)
            title = floor
        }
        // Dropped only when it gets less than its ideal width and less than 60; a meta at its full width stays.
        if meta < metaFloor, meta < metaIdeal {
            return Solution(titleWidth: min(titleIdeal, alone), metaWidth: nil, metaDropped: true, badgeWidth: nil)
        }
        return Solution(titleWidth: title, metaWidth: meta, metaDropped: false, badgeWidth: nil)
    }

    /// The fixed parts and the title floor do not fit: meta goes, the badge label truncates, then the title shrinks.
    private nonisolated static func overBudget(titleIdeal: CGFloat, dropsMeta: Bool, fixed: [CGFloat], cap: CGFloat,
                                               badge badgeSpec: (index: Int, minimum: CGFloat)?) -> Solution {
        let gaps = spacing * CGFloat(fixed.count)
        let badgeIdeal = badgeSpec.map { fixed[$0.index] } ?? 0
        let others = fixed.reduce(0, +) - badgeIdeal
        let floor = min(titleIdeal, titleFloor)
        var badge: CGFloat?
        var badgeUsed = badgeIdeal
        if let badgeSpec {
            badgeUsed = max(min(badgeSpec.minimum, badgeIdeal), min(badgeIdeal, cap - others - gaps - floor))
            badge = badgeUsed < badgeIdeal ? badgeUsed : nil
        }
        let title = max(0, min(titleIdeal, cap - others - gaps - badgeUsed))
        return Solution(titleWidth: title, metaWidth: nil, metaDropped: dropsMeta, badgeWidth: badge)
    }

    // MARK: Layout

    private struct Ideals {
        var title: CGSize = .zero
        var meta: CGSize?
        var fixed: [CGSize] = []
        var badgeIndex: Int?
        /// The badge's narrowest drawing: indicator, clock, suffix and padding, with the label truncated.
        var badgeMinimum: CGFloat = 0
        var height: CGFloat { ([title.height, meta?.height ?? 0] + fixed.map(\.height)).max() ?? 0 }
    }

    private func ideals(_ subviews: Subviews) -> Ideals {
        var result = Ideals()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            switch subview[RoleKey.self] {
            case .title: result.title = size
            case .meta: result.meta = size
            case .badge:
                result.badgeIndex = result.fixed.count
                result.badgeMinimum = subview.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
                result.fixed.append(size)
            case .busy, .status: result.fixed.append(size)
            }
        }
        return result
    }

    private func solution(_ ideals: Ideals) -> Solution {
        Self.solve(titleIdeal: ideals.title.width, metaIdeal: ideals.meta?.width, fixed: ideals.fixed.map(\.width), cap: cap,
                   badgeIndex: ideals.badgeIndex, badgeMinimum: ideals.badgeMinimum, titleFloor: titleFloor,
                   metaMayTruncate: metaMayTruncate)
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let ideals = ideals(subviews)
        let solution = solution(ideals)
        var fixedWidth = ideals.fixed.map(\.width).reduce(0, +)
        if let index = ideals.badgeIndex, let badge = solution.badgeWidth { fixedWidth += badge - ideals.fixed[index].width }
        let count = ideals.fixed.count + 1 + (solution.metaWidth == nil ? 0 : 1)
        let width = fixedWidth + solution.titleWidth + (solution.metaWidth ?? 0) + Self.spacing * CGFloat(count - 1)
        return CGSize(width: width, height: ideals.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let ideals = ideals(subviews)
        let solution = solution(ideals)
        let metaDropped = ideals.meta != nil && solution.metaWidth == nil
        // SwiftUI lays out on the main thread; the Layout witness is just not annotated as main-actor.
        MainActor.assumeIsolated { probe?.record(metaDropped: metaDropped) }
        var x = bounds.minX
        for subview in subviews {
            let role = subview[RoleKey.self]
            let size = subview.sizeThatFits(.unspecified)
            let width: CGFloat = switch role {
            case .title: solution.titleWidth
            case .meta: solution.metaWidth ?? 0
            case .badge: solution.badgeWidth ?? size.width
            case .busy, .status: size.width
            }
            if role == .meta, solution.metaWidth == nil {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: 0, height: 0))
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: size.height))
            x += width + Self.spacing
        }
    }
}

extension View {
    /// Tags this view's role for `TopBarPrincipalLayout`.
    func topBarRole(_ role: TopBarPrincipalLayout.Role) -> some View {
        layoutValue(key: TopBarPrincipalLayout.RoleKey.self, value: role)
    }
}

// MARK: - GroupTopBarBudget

/// A group's principal width budget: the detail column's width minus the two toolbar buttons (reserved whether or
/// not Cancel all shows, so the meta cannot toggle when the last task settles) minus the bar's margins. The
/// buttons' widths are constants computed once from their labels and `TopBarButtonStyle`'s padding.
enum GroupTopBarBudget {
    /// The title never goes below this while the badge and meta decision are made.
    static let titleFloor: CGFloat = 160

    /// `.hd-btn`: 13/18 weight 500, padding 0 12, plus the danger button's 1 pt border.
    static let viewPromptWidth: CGFloat = buttonWidth("View prompt", border: 0)
    static let cancelAllWidth: CGFloat = buttonWidth("Cancel all", border: 1)

    /// Both buttons, the gap between them and the gaps either side.
    static var reservedButtons: CGFloat {
        viewPromptWidth + cancelAllWidth + TaskScreenStyle.TopBar.actionsGap + 2 * TaskScreenStyle.TopBar.gap
    }

    /// The bar's own margins.
    static let margins = TaskScreenStyle.TopBar.paddingLeading + TaskScreenStyle.TopBar.paddingTrailing

    /// The principal's cap for a detail column of `detailWidth`; never negative. The principal is a centred toolbar
    /// item, so with a `windowWidth` the cap is also at most twice the room between the window's centre and the
    /// trailing buttons: `2 × (windowWidth / 2 − reserved buttons − margin)`.
    static func cap(detailWidth: CGFloat, windowWidth: CGFloat? = nil) -> CGFloat {
        let leading = max(0, detailWidth - reservedButtons - margins)
        guard let windowWidth else { return leading }
        let centred = max(0, 2 * (windowWidth / 2 - reservedButtons - margins))
        return min(leading, centred)
    }

    private static func buttonWidth(_ label: String, border: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let text = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 2 * TopBarButtonStyle.paddingHorizontal + 2 * border
    }
}
