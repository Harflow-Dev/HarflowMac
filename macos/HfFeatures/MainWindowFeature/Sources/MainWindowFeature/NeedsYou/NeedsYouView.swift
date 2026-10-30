import HfCommon
import HfUI
import SwiftUI

// MARK: - NeedsYouViewModel

@MainActor
protocol NeedsYouViewModel: ViewModel {
    var presentation: NeedsYouPresentation { get }
    var answerText: String { get set }
    var additionalAttempts: Int { get set }
    func didAppear()
    func didDisappear()
    func show(itemID: String?)
    func didSelect(_ itemID: String)
    func didTapBack()
    func didTapRetry()
    func didDismissNotice()
    func didSubmitAnswer()
    func didChooseOffered(_ answer: String)
    func didDecide(approve: Bool)
    func didChangeReduceMotion(_ value: Bool)
}

// MARK: - NeedsYouView

/// The Needs you pane: the list, or one request's detail when `itemID` is set.
struct NeedsYouView<VM: NeedsYouViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride
    @State private var viewModel: VM
    let itemID: String?

    init(_ viewModel: VM, itemID: String?) {
        _viewModel = State(initialValue: viewModel)
        self.itemID = itemID
    }

    private var reduceMotion: Bool { HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion) }

    var body: some View {
        Group {
            if viewModel.presentation.showsDetail {
                NeedsYouDetailView(viewModel: viewModel)
            } else {
                NeedsYouListView(viewModel: viewModel, reduceMotion: reduceMotion)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.windowBG)
        .onAppear {
            viewModel.didChangeReduceMotion(reduceMotion)
            viewModel.didAppear()
            viewModel.show(itemID: itemID)
        }
        .onDisappear { viewModel.didDisappear() }
        .onChange(of: itemID) { _, new in viewModel.show(itemID: new) }
        .onChange(of: reduceMotion) { _, new in viewModel.didChangeReduceMotion(new) }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

// MARK: - NeedsYouAgeText

/// Renders a minute-granularity age from a clock-driven child, so snapshots never republish for time.
struct NeedsYouAgeText: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.everyMinute) { context in
                Text(Self.age(since: since, now: context.date))
            }
        }
    }

    static func age(since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(Int((Double(minutes) / 60).rounded())) h ago"
    }
}

// MARK: - NeedsYouKindChip

struct NeedsYouKindChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.hf(.caption, weight: .semibold))
            .padding(.horizontal, HfRadius.Metrics.spacing6)
            .padding(.vertical, HfRadius.Metrics.spacing2)
            .background(Color.warningBG, in: Capsule())
            .foregroundStyle(Color.warningFG)
    }
}

// MARK: - NeedsYouPath

struct NeedsYouPath: View {
    let titles: [String]

    var body: some View {
        Text(titles.joined(separator: " › "))
            .font(.hf(.caption))
            .foregroundStyle(Color.secondaryText)
            .accessibilityLabel("Path: \(titles.joined(separator: ", "))")
    }
}
