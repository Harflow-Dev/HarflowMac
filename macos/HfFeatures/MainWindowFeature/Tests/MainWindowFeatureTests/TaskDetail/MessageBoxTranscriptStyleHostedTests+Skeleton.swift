import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - MessageBoxTranscriptStyleHostedTests + skeleton

/// The transcript loading skeleton against the loaded task: bubble fill and trailing inset, composer surface and
/// position, so nothing moves or changes colour when the content arrives. An extension, so the tests stay serialized.
extension MessageBoxTranscriptStyleHostedTests {
    static let skeletonHeader = TaskLoadingHeader(title: "Fix the flaky slot test", repoName: "slots")

    static func skeleton(_ style: ActivityFeedStyle) -> AnyView {
        AnyView(NavigationStack { TaskLoadingSkeleton(header: skeletonHeader, style: style) }
            .environment(\.shimmerReduceMotionOverride, true))
    }

    @Test(arguments: [false, true])
    func givenSkeletonAndLoadedComposer_whenMeasured_thenSurfaceFillWidthAndPositionMatchWithNoJump(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 800)
        let surface = try await token(TaskScreenStyle.Colors.surface, dark: dark)
        let loaded = fixture(Self.composerStack(Self.enabledModel, style: .transcript, dark: dark), size: size, dark: dark)
        defer { loaded.close() }
        await loaded.settle { Self.editableField(in: loaded) != nil }
        let placeholder = fixture(Self.skeleton(.transcript)
.preferredColorScheme(dark ? .dark : .light)
            .environment(\.hfReduceMotionOverride, true), size: size, dark: dark)
        defer { placeholder.close() }
        await DisplayFrames.waitForPresentedFrame()
        var passes = 0
        await placeholder.settle { passes += 1; return passes >= 30 }
        await loaded.settle { passes += 1; return passes >= 60 }

        // when
        let columnX = size.width / 2 - 340
        let rightX = size.width / 2 + 340
        let skeletonShot = Shot(placeholder.host)
        let loadedShot = Shot(loaded.host)
        let skeleton = try #require(skeletonShot.composerBounds(surface: surface, columnX: columnX, rightX: rightX), "skeleton composer not found")
        let real = try #require(loadedShot.composerBounds(surface: surface, columnX: columnX, rightX: rightX), "loaded composer not found")
        print("MB-SKELETON dark=\(dark) skeleton=\(skeleton) loaded=\(real)")

        // then — same fill (the token), same x extent, same y and height: the surface does not move on load.
        #expect(abs(skeleton.minX - real.minX) <= 1 && abs(skeleton.width - real.width) <= 1,
                "x \(skeleton.minX)/\(skeleton.width) vs \(real.minX)/\(real.width)")
        #expect(abs(skeleton.minY - real.minY) <= 1.5, "composer top: skeleton \(skeleton.minY), loaded \(real.minY)")
        #expect(abs(skeleton.height - real.height) <= 1.5, "composer height: skeleton \(skeleton.height), loaded \(real.height)")
        #expect(abs(skeleton.width - 696) <= 1.5)
    }

    @Test(arguments: [false, true])
    func givenSkeletonAndLoadedPrompt_whenMeasured_thenBubbleFillAndTrailingInsetMatch(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 800)
        let bubble = try await token(TaskScreenStyle.UserBubble.fill, dark: dark)
        let placeholder = fixture(Self.skeleton(.transcript)
.preferredColorScheme(dark ? .dark : .light)
            .environment(\.hfReduceMotionOverride, true), size: size, dark: dark)
        defer { placeholder.close() }
        let mock = TaskDetailViewModelMock.finished()
        let taskID = ActivityFeedTranscriptStyleHostedTests.taskID
        mock.timelineModel = ActivityFeedTranscriptStyleHostedTests.timelineModel([
            ActivityFixture.message(0, String(repeating: "Find out why the slot test is flaky and fix it. ", count: 12), source: "initial", task: taskID),
            ActivityFixture.text(1, "On it.", task: taskID)
        ])
        let loaded = fixture(TaskDetailView(mock, transcriptStyle: .transcript)
.preferredColorScheme(dark ? .dark : .light)
            .environment(\.hfReduceMotionOverride, true), size: size, dark: dark)
        defer { loaded.close() }
        await DisplayFrames.waitForPresentedFrame()
        var passes = 0
        await placeholder.settle { passes += 1; return passes >= 40 }
        await loaded.settle { passes += 1; return passes >= 80 }
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(loaded.host).first)
        let column = table.convert(table.bounds, to: loaded.host)

        // when
        let skeletonArea = CGRect(x: 320, y: 0, width: 760, height: 500)
        let loadedArea = column.intersection(CGRect(x: 0, y: 0, width: 1400, height: 500))
        let skeletonBubble = try #require(Shot(placeholder.host).bubbleBounds(fill: bubble, in: skeletonArea), "no skeleton bubble")
        let loadedBubble = try #require(Shot(loaded.host).bubbleBounds(fill: bubble, in: loadedArea), "no loaded bubble")
        print("MB-BUBBLE dark=\(dark) skeleton=\(skeletonBubble) loaded=\(loadedBubble) column=\(column)")

        // then — both are the --surface-active token (same rendering pipeline); trailing inset from the 760 column is 32 in both.
        #expect(abs((1080 - skeletonBubble.maxX) - 32) <= 1.5, "skeleton bubble trailing inset \(1080 - skeletonBubble.maxX)")
        #expect(abs((column.maxX - loadedBubble.maxX) - 32) <= 1.5, "loaded bubble trailing inset \(column.maxX - loadedBubble.maxX)")
        #expect(abs(skeletonBubble.width - 460) <= 1.5, "skeleton bubble width \(skeletonBubble.width)")
        #expect(loadedBubble.width <= 0.8 * 696 + 1.5, "loaded bubble width \(loadedBubble.width)")
    }

    @Test(arguments: [false, true])
    func givenStandardSkeleton_whenSampled_thenItMatchesTheBaseCommitRender(dark: Bool) async throws {
        // given / when
        let mask = try await ComposerMeasure.skeletonMask(dark: dark) { Self.skeleton(.standard) }
        // then — the shapes (bars, cards, bubble, composer capsule) sit where they did at the base commit.
        let base = dark ? BaseStandardRender.skeletonDark : BaseStandardRender.skeletonLight
        #expect(mask.count == base.count)
        let differing = zip(mask, base).enumerated().filter { $1.0 != $1.1 }.map(\.offset)
        #expect(differing.isEmpty, "standard skeleton rows differ from base: \(differing.map { "\($0) now \(mask[$0]) base \(base[$0])" })")
    }

    @Test(arguments: [false, true])
    func givenStandardComposer_whenMeasured_thenGeometryAndPixelsMatchTheBaseCommit(dark: Bool) async throws {
        // given / when — default style, then the explicit `.standard`: both are measured with the same code that measured the base.
        let implicit = try await ComposerMeasure.standard(dark: dark) { model in
            AnyView(VStack(spacing: 0) {
                Color.clear
                MessageBoxView(model: model, onSubmitNow: { _ in true }) { _ in true }.readingColumn()
            }.background(Color.windowBG))
        }
        let explicit = try await ComposerMeasure.standard(dark: dark) { model in
            AnyView(VStack(spacing: 0) {
                Color.clear
                MessageBoxView(model: model, onSubmitNow: { _ in true }, style: .standard) { _ in true }.readingColumn()
            }.background(Color.windowBG))
        }
        // then
        #expect(implicit == explicit, "default and explicit .standard differ: \(implicit.summary) / \(explicit.summary)")
        let base = dark ? BaseStandardRender.composerDark : BaseStandardRender.composerLight
        for (name, got, want) in [("send", implicit.send, base.send), ("sendNow", implicit.sendNow, base.sendNow),
                                  ("field", implicit.field, base.field), ("hint", implicit.hint, base.hint)] {
            #expect(abs(got.minX - want.minX) <= 0.5 && abs(got.minY - want.minY) <= 0.5
                && abs(got.width - want.width) <= 0.5 && abs(got.height - want.height) <= 0.5, "\(name) \(got), base \(want)")
        }
        #expect(implicit.fieldHeights == base.fieldHeights, "field heights \(implicit.fieldHeights), base \(base.fieldHeights)")
        #expect(zip(implicit.pixels, base.pixels).map { abs($0 - $1) }.max() ?? 99 <= 2, "pixels \(implicit.pixels), base \(base.pixels)")
    }
}

extension Shot {
    /// The bounds of the first contiguous band of rows holding at least 30 pt of `fill`-coloured pixels inside `rect`.
    func bubbleBounds(fill: [Int], in rect: CGRect) -> CGRect? {
        var minX = Int.max
        var maxX = -1
        var top: Int?
        var bottom = 0
        var gap = 0
        for y in Int(rect.minY * scale) ..< Int(rect.maxY * scale) {
            var rowMin = Int.max
            var rowMax = -1
            var count = 0
            for x in Int(rect.minX * scale) ..< Int(rect.maxX * scale) where Self.close(rgb(px: x, y), fill, 1) {
                rowMin = min(rowMin, x)
                rowMax = max(rowMax, x)
                count += 1
            }
            if CGFloat(count) >= 30 * scale {
                top = top ?? y
                bottom = y
                gap = 0
                minX = min(minX, rowMin)
                maxX = max(maxX, rowMax)
            } else if top != nil {
                gap += 1
                if CGFloat(gap) > 10 * scale { break }
            }
        }
        guard let top else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(top) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }
}
