import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - MessageBoxTranscriptStyleHostedTests

/// Hosted behaviour of `MessageBoxStyle.transcript`: the measured width, centring, bottom gap, surface, border,
/// field and send-button metrics of the task screen's composer, the locked states, and that `.standard` is
/// unchanged. Geometry is read from rendered pixels and the hosted view tree; colours are compared with the
/// design tokens rendered through the same pipeline, because an offscreen bitmap shifts absolute values.
/// An extension of this suite holds the mount, base-commit and skeleton tests, so they stay serialized with it.
@MainActor @Suite(.serialized) struct MessageBoxTranscriptStyleHostedTests {

    // MARK: Fixtures

    static let enabledModel = MessageBoxModel(
        canSend: true, canContinue: false, isBusy: false, label: "Message this task",
        hint: "Send queues; Send now requests immediate delivery when safe", placeholder: "Queue a message…",
        buttonLabel: "Send"
    )
    static let lockedModel = MessageBoxModel(
        canSend: false, canContinue: false, isBusy: false, label: "Messages", hint: "",
        placeholder: MessageBoxDisabledReason.takenOver.text, buttonLabel: "Send", isLocked: true
    )

    /// A composer in the same wrapper the task detail uses (`readingColumn()` under the content), on the page token.
    static func composerStack(_ model: MessageBoxModel, style: MessageBoxStyle, sink: SubmitSink = SubmitSink(),
                              withSendNow: Bool = false, dark: Bool) -> some View {
        VStack(spacing: 0) {
            Color.clear
            MessageBoxView(model: model, onSubmitNow: withSendNow ? { sink.record("now:" + $0) } : nil, style: style) {
                sink.record($0)
            }
            .readingColumn()
        }
        .background(style == .transcript ? TaskScreenStyle.Colors.pageBackground.color : Color.windowBG)
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.hfReduceMotionOverride, true)
    }

    @MainActor final class SubmitSink {
        private(set) var values: [String] = []
        func record(_ value: String) -> Bool { values.append(value); return true }
    }

    func fixture(_ view: some View, size: CGSize, dark: Bool) -> RedesignHost {
        RedesignHost(view, size: size, appearance: dark ? .dark : .light)
    }

    // MARK: Geometry at a wide window

    @Test(arguments: [false, true])
    func givenWideWindow_whenTranscriptTaskDetailIsMounted_thenComposerIs696CentredOnTheFeedTextColumnAndEdgesAgree(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 800)
        let mock = TaskDetailViewModelMock.finished()
        mock.timelineModel = ActivityFeedTranscriptStyleHostedTests.timelineModel([
            ActivityFixture.text(1, "A short reply before the separator.", task: ActivityFeedTranscriptStyleHostedTests.taskID),
            ActivityFixture.separator("Also check the retry path.", task: ActivityFeedTranscriptStyleHostedTests.taskID),
            ActivityFixture.text(2, "A short reply after it.", task: ActivityFeedTranscriptStyleHostedTests.taskID)
        ])
        let page = fixture(TaskDetailView(mock, transcriptStyle: .transcript)
            .preferredColorScheme(dark ? .dark : .light)
.environment(\.hfReduceMotionOverride, true), size: size, dark: dark)
        defer { page.close() }
        await page.settle { ActivityFeedTranscriptStyleHostedTests.tables(page.host).first?.owner?.model != nil }
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let owner = try #require(table.owner)
        let separatorRow = try #require(owner.entries.firstIndex { $0.id == "sep:" + ActivityFeedTranscriptStyleHostedTests.taskID })
        await DisplayFrames.waitForPresentedFrame()
        var passes = 0
        await page.settle { passes += 1; return passes >= 40 }
        let surface = try await token(TaskScreenStyle.Colors.surface, dark: dark)

        // when
        let shot = Shot(page.host)
        let tableFrame = table.convert(table.bounds, to: page.host)
        let composer = try #require(shot.composerBounds(surface: surface, columnX: tableFrame.midX - 340, rightX: tableFrame.midX + 340),
                                    "no composer surface found")
        let band = table.convert(table.rect(ofRow: separatorRow), to: page.host)
        let ink = try #require(shot.inkBounds(inBand: band))

        // then — 696 wide, centred on the feed column (the inspector takes the window's right side), left and right edges equal the feed text's (the separator rules span the measure).
        #expect(abs(composer.width - 696) <= 1.5, "composer width \(composer.width)")
        #expect(abs(composer.midX - tableFrame.midX) <= 1, "composer centre \(composer.midX), feed column centre \(tableFrame.midX)")
        #expect(abs(composer.minX - ink.minX) <= 2, "composer left \(composer.minX), feed text left \(ink.minX)")
        #expect(abs(composer.maxX - ink.maxX) <= 2, "composer right \(composer.maxX), feed text right \(ink.maxX)")
        #expect(abs((ink.maxX - ink.minX) - 696) <= 2, "feed text measure \(ink.maxX - ink.minX)")
    }

    @Test(arguments: [false, true])
    func givenComposerWithAndWithoutAHint_whenMeasured_thenBottomGapIsTheWrapperPaddingPlusTheHintBlock(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 600)
        let surface = try await token(TaskScreenStyle.Colors.surface, dark: dark)
        func bottomGap(_ model: MessageBoxModel) async throws -> CGFloat {
            let page = fixture(Self.composerStack(model, style: .transcript, dark: dark), size: size, dark: dark)
            defer { page.close() }
            await page.settle { page.element(model.placeholder) != nil || model.isLocked }
            await DisplayFrames.waitForPresentedFrame()
            page.host.layoutSubtreeIfNeeded()
            let composer = try #require(Shot(page.host).composerBounds(surface: surface, columnX: size.width / 2 - 340, rightX: size.width / 2 + 340))
            return size.height - composer.maxY
        }

        // when — a locked composer prints no hint; an enabled one prints the ⌘↩ line under the surface.
        let locked = try await bottomGap(Self.lockedModel)
        let enabled = try await bottomGap(Self.enabledModel)

        // then — 24 is `ComposerWrapper.paddingBottom`; the enabled gap adds 8 (stack spacing) and one 12 pt text line.
        #expect(abs(locked - TaskScreenStyle.ComposerWrapper.paddingBottom) <= 1.5, "locked bottom gap \(locked)")
        let hintBlock = enabled - locked
        #expect(hintBlock >= 8 + 12 && hintBlock <= 8 + 18, "hint block \(hintBlock) (gap enabled \(enabled), locked \(locked))")
    }

    // MARK: Surface

    @Test(arguments: [false, true])
    func givenTranscriptComposer_whenRendered_thenFillIsTheSurfaceTokenNotThePageAndABorderPixelIsPresent(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 600)
        let surface = try await token(TaskScreenStyle.Colors.surface, dark: dark)
        let border = try await token(TaskScreenStyle.Colors.border, dark: dark)
        let pageBackground = try await token(TaskScreenStyle.Colors.pageBackground, dark: dark)
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, dark: dark), size: size, dark: dark)
        defer { page.close() }
        await page.settle { page.element("Queue a message…") != nil }
        await DisplayFrames.waitForPresentedFrame()
        page.host.layoutSubtreeIfNeeded()
        let shot = Shot(page.host)

        // when
        let composer = try #require(shot.composerBounds(surface: surface, columnX: size.width / 2 - 340, rightX: size.width / 2 + 340))
        let inside = shot.rgb(at: CGPoint(x: composer.minX + 8, y: composer.minY + 6))
        let outside = shot.rgb(at: CGPoint(x: composer.minX - 24, y: composer.midY))
        let edge = (0 ..< 3).map { shot.rgb(at: CGPoint(x: composer.minX + 0.25 + CGFloat($0) * 0.5, y: composer.midY)) }

        // then
        #expect(Shot.close(inside, surface, 1), "composer pixel \(inside), --surface \(surface)")
        #expect(!Shot.close(inside, pageBackground, 1), "composer pixel \(inside) equals the page --bg \(pageBackground)")
        #expect(Shot.close(outside, pageBackground, 6), "pixel beside the composer \(outside), page --bg \(pageBackground)")
        #expect(edge.contains { Shot.close($0, border, 3) }, "no --border pixel \(border) on the left edge: \(edge)")
        #expect(!Shot.close(border, surface, 1) && !Shot.close(border, pageBackground, 1))
    }

    @Test(arguments: [false, true])
    func givenStandardComposer_whenRenderedInTheSameFrame_thenItIsNotTheTranscriptSurfaceToken(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 600)
        let surface = try await token(TaskScreenStyle.Colors.surface, dark: dark)
        let page = fixture(Self.composerStack(Self.enabledModel, style: .standard, dark: dark), size: size, dark: dark)
        defer { page.close() }
        await page.settle { page.element("Queue a message…") != nil }
        await DisplayFrames.waitForPresentedFrame()
        page.host.layoutSubtreeIfNeeded()

        // when — no run of surface-token pixels the size of a composer exists in the standard (glass) capsule.
        let found = Shot(page.host).composerBounds(surface: surface, columnX: size.width / 2 - 340, rightX: size.width / 2 + 340)

        // then
        #expect(found == nil, "the standard composer paints the transcript --surface token: \(String(describing: found))")
    }

    // MARK: Field

    @Test func givenTranscriptComposer_whenValueGrowsLineByLine_thenFieldHasAMinimumHeightGrowsAndStopsAtSixLines() async throws {
        // given
        let size = CGSize(width: 1400, height: 700)
        let page = fixture(Self.composerStack(Self.enabledModel, style: .transcript, dark: false), size: size, dark: false)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        let send = try #require(page.element("Send"))
        await DisplayFrames.waitForPresentedFrame()

        // when
        let empty = Self.height(of: field, in: page)
        var heights: [Int: CGFloat] = [:]
        var tops: [Int: CGFloat] = [:]
        for lines in 1 ... 8 {
            await Self.type(String(repeating: "line\n", count: lines - 1) + "line", into: field, in: page)
            heights[lines] = Self.height(of: field, in: page)
            tops[lines] = field.convert(field.bounds, to: page.host).minY
        }
        await Self.type("HHH\nHHH\nHHH", into: field, in: page)
        let surfaceToken = try await token(TaskScreenStyle.Colors.surface, dark: false)
        let visual = Self.glyphLineStarts(in: Shot(page.host), frame: field.convert(field.bounds, to: page.host), surface: surfaceToken)
        print("MB-VISUAL line starts \(visual)")
        let advance = (heights[2] ?? 0) - (heights[1] ?? 0)
        let composerRowHeight = page.frame(send).map { page.host.convert($0, from: nil).height } ?? 0
        let sendFrame = try #require(page.frame(send).map { page.host.convert($0, from: nil) })
        let fieldFrame = field.convert(field.bounds, to: page.host)
        print("MB-METRIC empty=\(empty) heights=\(heights.sorted { $0.key < $1.key }.map(\.value)) advance=\(advance) send=\(composerRowHeight)")

        // then — grows one line at a time by the line advance, stops at six lines.
        #expect(heights[1] ?? 0 > 0)
        #expect((heights[6] ?? 0) > (heights[1] ?? 0) + 4 * 20, "six lines \(heights[6] ?? 0) vs one \(heights[1] ?? 0)")
        #expect(abs((heights[7] ?? 0) - (heights[6] ?? 0)) < 1 && abs((heights[8] ?? 0) - (heights[6] ?? 0)) < 1,
                "field kept growing past six lines: \(heights)")
        for lines in 2 ... 6 {
            #expect(abs((heights[lines] ?? 0) - (heights[lines - 1] ?? 0) - advance) < 1, "growth to \(lines) lines: \(heights)")
        }
        // The design advance is 22 (14/22). Measured: the field's frame and its rendered glyph rows both advance by 17
        // (`.lineSpacing` has no effect on a vertical-axis TextField), a recorded deviation. Pinned at the measured value.
        #expect(abs(advance - 17) <= 0.5, "measured line advance \(advance); design \(TaskScreenStyle.Composer.inputText.lineHeight)")
        #expect(visual.count >= 3 && abs((visual[1] - visual[0]) - advance) <= 1 && abs((visual[2] - visual[1]) - advance) <= 1,
                "glyph line starts \(visual) vs frame advance \(advance)")
        // Field and actions stay in one row: the field's vertical extent overlaps the send button's at every size.
        #expect(fieldFrame.maxX <= sendFrame.minX + 1, "field \(fieldFrame) and send \(sendFrame) share a row")
        #expect(fieldFrame.minY < sendFrame.maxY && fieldFrame.maxY > sendFrame.minY, "field \(fieldFrame) and send \(sendFrame) do not overlap vertically")
    }

    // MARK: Helpers

    static func editableField(in page: RedesignHost) -> NSTextField? {
        page.descendants.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    static func height(of field: NSTextField, in page: RedesignHost) -> CGFloat {
        field.convert(field.bounds, to: page.host).height
    }

    /// The y of the top ink row of each text line inside `frame`, found as runs of rows that differ from the surface.
    static func glyphLineStarts(in shot: Shot, frame: CGRect, surface: [Int]) -> [CGFloat] {
        var starts: [CGFloat] = []
        var inInk = false
        for y in Int((frame.minY - 4) * shot.scale) ..< Int((frame.maxY + 4) * shot.scale) {
            let hasInk = (Int(frame.minX * shot.scale) ..< Int((frame.minX + 60) * shot.scale)).contains { !Shot.close(shot.rgb(px: $0, y), surface, 40) }
            if hasInk, !inInk { starts.append(CGFloat(y) / shot.scale) }
            inInk = hasInk
        }
        return starts
    }

    static func type(_ text: String, into field: NSTextField, in page: RedesignHost) async {
        _ = page.window.makeFirstResponder(field)
        field.stringValue = text
        field.currentEditor()?.string = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        var passes = 0
        await page.settle { passes += 1; return passes >= 6 }
    }

    /// The token's colour through the same render pipeline as the composer: the reference swatch.
    func token(_ token: TaskScreenStyle.Token, dark: Bool) async throws -> [Int] {
        let swatch = fixture(token.color.preferredColorScheme(dark ? .dark : .light), size: CGSize(width: 120, height: 80), dark: dark)
        defer { swatch.close() }
        await DisplayFrames.waitForPresentedFrame()
        swatch.host.layoutSubtreeIfNeeded()
        return Shot(swatch.host).rgb(at: CGPoint(x: 60, y: 40))
    }
}
