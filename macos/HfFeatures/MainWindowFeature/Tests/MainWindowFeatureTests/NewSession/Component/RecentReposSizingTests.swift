import AppKit
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

/// Windowless sizing: measures the Recent row through `NSHostingController.sizeThatFits(in:)`
/// at the repository popover's content width; no window is created or shown.
@MainActor
@Suite struct RecentReposSizingTests {

    /// The repository popover is 360 points wide with 16 points of padding on each side.
    private let contentWidth: CGFloat = 328

    private func height(of repos: [RecentRepoModel], width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: RecentRepos(repos: repos, onSelect: { _ in }))
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// The chip's own ideal width (no width proposed), without the row's label or spacing.
    private func chipWidth(_ repo: RecentRepoModel) -> CGFloat {
        NSHostingController(rootView: RecentRepoChip(repo: repo, onSelect: { _ in })).view.fittingSize.width
    }

    private func size(of repos: [RecentRepoModel], width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: RecentRepos(repos: repos, onSelect: { _ in }))
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func repo(_ name: String) -> RecentRepoModel {
        RecentRepoModel(path: "/Users/me/Code/\(name)", name: name, isSelected: false)
    }

    @Test func givenOneShortChip_whenMeasured_thenTheRowIsOneChipTall() {
        // given / when
        let single = height(of: [repo("app")], width: contentWidth)

        // then
        #expect(single > 0 && single < 30)
    }

    @Test func givenFiveLongNames_whenMeasuredAtPopoverWidth_thenChipsWrapWholeNotCharacterByCharacter() {
        // given
        let single = height(of: [repo("app")], width: contentWidth)
        let names = [
            "HarflowEngine", "HarflowMCP", "r10-workflow-definitions-e2f0c3", "HarflowDesign",
            "a-very-long-repository-name-that-cannot-fit-on-one-line-anywhere"
        ]

        // when
        let measured = size(of: names.map(repo), width: contentWidth)

        // then: five chips wrapped as whole chips need at most five chip rows plus row spacing,
        // and a squeezed chip (one or two characters per line) is many times taller than that.
        #expect(measured.height <= single * 5 + 6 * 4 + 1, "row height \(measured.height) for single-chip height \(single)")
        // They do not all fit one row, so whole chips wrap onto several rows rather than squeezing into one.
        #expect(measured.height > single * 1.5, "row height \(measured.height) is a single row of height \(single)")
        // Every chip is one line: the height is exactly n rows of one chip plus the gaps between them.
        let fitsWholeRows = (2 ... 5).contains { rows in
            abs(measured.height - (CGFloat(rows) * single + CGFloat(rows - 1) * 6)) <= 1
        }
        #expect(fitsWholeRows, "row height \(measured.height) is not a whole number of one-line rows of height \(single)")
    }

    @Test func givenOneVeryLongName_whenMeasured_thenTheChipStaysOneLine() {
        // given
        let single = height(of: [repo("app")], width: contentWidth)

        // when
        let long = height(of: [repo(String(repeating: "workflow-definitions-", count: 6))], width: contentWidth)

        // then
        #expect(long <= single + 1, "long chip height \(long) vs \(single)")
        // The chip itself grows to at most the 240 point maximum plus its 8 point side padding.
        let chip = chipWidth(repo(String(repeating: "workflow-definitions-", count: 6)))
        #expect(chip <= HfRadius.Metrics.recentRepoChipMaxWidth + 2 * HfRadius.Metrics.spacing8 + 1, "long chip is \(chip) wide")
    }
}
