import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

/// The layer indicators inside `ActivityFeedNativeCell`: animation count across reuse transitions,
/// and the accessibility tree the cell publishes.
@MainActor @Suite(.serialized) struct LayerMotionFeedHostedTests {
    private struct Mounted {
        let fixture: LayerMotionFixture
        let cell: ActivityFeedNativeCell
        let actions: ActivityFeedNativeActions
    }

    private func mount(width: CGFloat = 403) -> Mounted {
        let fixture = LayerMotionFixture(size: CGSize(width: 420, height: 300))
        let cell = ActivityFeedNativeCell(frame: CGRect(x: 0, y: 100, width: width, height: 150))
        fixture.container.addSubview(cell)
        fixture.enableAccessibility()
        return Mounted(fixture: fixture, cell: cell, actions: ActivityFeedNativeActions())
    }

    private func root(_ entry: ActivityFeedNativeEntry, mounted: Mounted, style: ActivityFeedStyle = .standard,
                      reduceMotion: Bool? = false) -> ActivityFeedNativeRowRoot {
        var values = EnvironmentValues()
        values.hfReduceMotionOverride = reduceMotion
        return ActivityFeedNativeRowRoot(entry: entry, start: nil, horizontalPadding: 12, showsPromptBubble: true, style: style,
                                         environment: ActivityFeedNativeEnvironment(values), actions: mounted.actions, availableWidth: 403)
    }

    private func configure(_ mounted: Mounted, _ entry: ActivityFeedNativeEntry, style: ActivityFeedStyle = .standard,
                           reduceMotion: Bool? = false) {
        mounted.cell.configure(root: root(entry, mounted: mounted, style: style, reduceMotion: reduceMotion), id: entry.id)
    }

    private func textEntry(_ seq: Int, streaming: Bool, text: String = "hello world") -> ActivityFeedNativeEntry {
        .row(.init(row: .single(ActivityFixture.text(seq, text, streaming: streaming)), isExpanded: false, fade: false, topSpacing: 12))
    }

    private func toolEntry(_ seq: Int, resolved: Bool) -> ActivityFeedNativeEntry {
        .row(.init(row: .single(ActivityFixture.tool(seq, category: "shell", command: "make test", resolved: resolved)),
                   isExpanded: false, fade: false, topSpacing: 12))
    }

    private func groupEntry(running: Bool, expanded: Bool) -> ActivityFeedNativeEntry {
        let call = ActivityFixture.call("c1", tool: "Read", category: "read", path: "/repo/AppDelegate.swift")
        let result: TaskEvent.ToolResult? = running ? nil : ActivityFixture.result("c1")
        let member = ToolGroupMember(id: "member", call: call, result: result, timestamp: nil, live: running)
        let group = ToolGroup(id: "group", taskID: "t1", bucket: .read, members: [member])
        return .row(.init(row: .toolGroup(group), isExpanded: expanded, fade: false, topSpacing: 12))
    }

    private func liveStepEntry() -> ActivityFeedNativeEntry {
        .tail(.standard(.init(liveStep: .init(text: "Thinking about the plan", indicator: .singleDot))), topSpacing: 12)
    }

    private func carets(_ mounted: Mounted) -> [LayerCaretView] { LayerMotionProbe.views(LayerCaretView.self, in: mounted.cell) }
    private func spinners(_ mounted: Mounted) -> [LayerSpinnerView] { LayerMotionProbe.views(LayerSpinnerView.self, in: mounted.cell) }
    private func dots(_ mounted: Mounted) -> [LayerPulseDotView] { LayerMotionProbe.views(LayerPulseDotView.self, in: mounted.cell) }
    private func animations(_ mounted: Mounted) -> Int { LayerMotionProbe.count(in: mounted.cell) }

    // MARK: Streaming caret across reuse

    @Test func givenStreamingRow_whenMounted_thenExactlyOneCaretAnimates() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        // when
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { carets(mounted).count == 1 && animations(mounted) == 1 }
        // then
        #expect(carets(mounted).count == 1)
        #expect(animations(mounted) == 1)
        #expect(carets(mounted).first?.isMotionInstalled == true)
    }

    @Test func givenSameId_whenStreamingSettlesAndStreamsAgain_thenOneAnimationAfterEachStep() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { animations(mounted) == 1 }
        let first = try #require(carets(mounted).first)
        // when: settled under the same id
        configure(mounted, textEntry(1, streaming: false))
        await waitUntil { carets(mounted).isEmpty }
        // then
        #expect(carets(mounted).isEmpty)
        #expect(animations(mounted) == 0)
        #expect(LayerMotionProbe.hasAnimation(first.layer) == false, "the removed caret is detached and carries nothing")
        #expect(first.window == nil)
        // when: streaming again
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { carets(mounted).count == 1 && animations(mounted) == 1 }
        // then
        #expect(carets(mounted).count == 1)
        #expect(animations(mounted) == 1)
        let second = try #require(carets(mounted).first)
        #expect(LayerMotionProbe.hasAnimation(first.layer) == false)
        #expect(second.isMotionInstalled)
    }

    @Test func givenAnimatingCell_whenReplacedByAnotherEntry_thenOldLayerIsBareAndOneAnimationRemains() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { animations(mounted) == 1 }
        let old = try #require(carets(mounted).first)
        let oldHost = try #require(mounted.cell.host)
        // when: a different streaming entry reuses the cell
        configure(mounted, textEntry(2, streaming: true, text: "another reply"))
        await waitUntil { carets(mounted).count == 1 && carets(mounted).first !== old && animations(mounted) == 1 }
        // then
        #expect(mounted.cell.host !== oldHost)
        #expect(carets(mounted).first !== old)
        #expect(carets(mounted).count == 1)
        #expect(animations(mounted) == 1)
        #expect(old.window == nil)
        #expect(LayerMotionProbe.hasAnimation(old.layer) == false)
        #expect(LayerMotionProbe.count(in: oldHost) == 0)
        // when: replaced by an entry with no indicator at all
        configure(mounted, textEntry(3, streaming: false))
        await waitUntil { carets(mounted).isEmpty }
        // then
        #expect(animations(mounted) == 0)
    }

    @Test func givenAnimatingCell_whenHostedContentIsReleased_thenNothingAnimates() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { animations(mounted) == 1 }
        let old = try #require(carets(mounted).first)
        let oldHost = try #require(mounted.cell.host)
        // when
        mounted.cell.releaseHostedContent()
        // then
        #expect(mounted.cell.host == nil)
        #expect(animations(mounted) == 0)
        #expect(old.window == nil)
        #expect(LayerMotionProbe.hasAnimation(old.layer) == false)
        #expect(LayerMotionProbe.count(in: oldHost) == 0)
        // when: the cell is reconfigured after release
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { carets(mounted).count == 1 && animations(mounted) == 1 }
        // then
        #expect(carets(mounted).count == 1)
        #expect(animations(mounted) == 1)
    }

    @Test func givenAnimatingCell_whenLeavingAndReenteringTheWindow_thenOneAnimationReturns() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, textEntry(1, streaming: true))
        await waitUntil { animations(mounted) == 1 }
        // when
        mounted.cell.removeFromSuperview()
        // then
        #expect(animations(mounted) == 0)
        // when
        mounted.fixture.container.addSubview(mounted.cell)
        // then
        #expect(animations(mounted) == 1)
    }

    @Test func givenStreamingRow_whenReduceMotionIsOn_thenCaretShowsAtFullOpacityWithoutAnimation() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        // when
        configure(mounted, textEntry(1, streaming: true), reduceMotion: true)
        await waitUntil { carets(mounted).count == 1 }
        // then
        #expect(carets(mounted).count == 1)
        #expect(animations(mounted) == 0)
        #expect(carets(mounted).first?.layer?.opacity == 1)
        // when: Reduce Motion goes off through the same hosted root
        configure(mounted, textEntry(1, streaming: true), reduceMotion: false)
        await waitUntil { animations(mounted) == 1 }
        // then
        #expect(animations(mounted) == 1)
        // when: and on again
        configure(mounted, textEntry(1, streaming: true), reduceMotion: true)
        await waitUntil { animations(mounted) == 0 }
        #expect(animations(mounted) == 0)
    }

    // MARK: Tool spinner

    @Test func givenPendingToolRow_whenMountedAndResolved_thenSpinnerAnimatesThenStops() async throws {
        for style in [ActivityFeedStyle.standard, .transcript] {
            // given
            let mounted = mount()
            defer { mounted.fixture.close() }
            // when
            configure(mounted, toolEntry(1, resolved: false), style: style)
            await waitUntil { spinners(mounted).count == 1 && animations(mounted) == 1 }
            // then
            #expect(spinners(mounted).count == 1, "\(style)")
            #expect(animations(mounted) == 1, "\(style)")
            let old = try #require(spinners(mounted).first)
            // when: the call resolves under the same id
            configure(mounted, toolEntry(1, resolved: true), style: style)
            await waitUntil { spinners(mounted).isEmpty }
            // then
            #expect(animations(mounted) == 0, "\(style)")
            #expect(LayerMotionProbe.count(in: old) == 0)
            #expect(old.window == nil)
        }
    }

    // MARK: Tool group card

    @Test func givenRunningToolGroupCard_whenMountedCollapsedAndExpanded_thenEverySpinnerSiteAnimatesAndSpeaks() async throws {
        for style in [ActivityFeedStyle.standard, .transcript] {
            for expanded in [false, true] {
                // given: the header spinner, plus the pending member's own tool-row spinner when expanded
                let mounted = mount()
                defer { mounted.fixture.close() }
                let sites = expanded ? 2 : 1
                let label = Comment(rawValue: "\(style) expanded=\(expanded)")
                // when
                configure(mounted, groupEntry(running: true, expanded: expanded), style: style)
                await waitUntil { spinners(mounted).count == sites && animations(mounted) == sites }
                await awaitTree(mounted) { $0.filter { mentionsRunning($0) }.count == sites }
                // then
                #expect(spinners(mounted).count == sites, label)
                #expect(animations(mounted) == sites, label)
                let allInstalled = spinners(mounted).allSatisfy(\.isMotionInstalled)
                #expect(allInstalled, label)
                let objects = publishedObjects(mounted.cell)
                #expect(objects.filter { mentionsRunning($0) }.count == sites, Comment(rawValue: "\(label) tree: \(describe(objects))"))
                #expect(!objects.contains { $0 is LayerSpinnerView }, label)
                // when: the group finishes under the same id
                let old = spinners(mounted)
                configure(mounted, groupEntry(running: false, expanded: expanded), style: style)
                await waitUntil { spinners(mounted).isEmpty }
                // then
                #expect(animations(mounted) == 0, label)
                #expect(old.allSatisfy { LayerMotionProbe.count(in: $0) == 0 && $0.window == nil }, label)
            }
        }
    }

    // MARK: Live step

    @Test func givenLiveStepTail_whenMounted_thenOnePulseAnimatesInStandardAndOneGlyphInTranscript() async throws {
        // given
        let standard = mount()
        defer { standard.fixture.close() }
        // when
        configure(standard, liveStepEntry())
        await waitUntil { dots(standard).count == 1 && animations(standard) == 1 }
        // then
        #expect(dots(standard).count == 1)
        #expect(spinners(standard).isEmpty)
        #expect(animations(standard) == 1)
        // given
        let transcript = mount()
        defer { transcript.fixture.close() }
        // when
        configure(transcript, liveStepEntry(), style: .transcript)
        await waitUntil { spinners(transcript).count == 1 && animations(transcript) == 1 }
        // then
        #expect(spinners(transcript).count == 1)
        #expect(dots(transcript).isEmpty)
        #expect(animations(transcript) == 1)
        let glyph = try #require(spinners(transcript).first)
        #expect(glyph.spec.margin == 1 && glyph.spec.diameter == 14 && glyph.spec.arcFraction == 0.25)
    }

    @Test func givenLiveStepTail_whenReplacedByBottomSentinelAndBack_thenOneAnimationReturns() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, liveStepEntry())
        await waitUntil { animations(mounted) == 1 }
        let old = try #require(dots(mounted).first)
        // when
        configure(mounted, .bottom(topSpacing: 20))
        // then
        #expect(animations(mounted) == 0)
        #expect(LayerMotionProbe.count(in: old) == 0)
        // when
        configure(mounted, liveStepEntry())
        await waitUntil { dots(mounted).count == 1 && animations(mounted) == 1 }
        // then
        #expect(dots(mounted).count == 1)
        #expect(animations(mounted) == 1)
    }

    // MARK: Accessibility

    private func publishedObjects(_ cell: ActivityFeedNativeCell) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            guard object.responds(to: selector),
                  let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return }
            for child in children { if let child = child as? NSObject { visit(child) } }
        }
        for child in cell.accessibilityChildren() ?? [] { if let child = child as? NSObject { visit(child) } }
        return result
    }

    private func texts(_ object: NSObject) -> [String] {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { name -> String? in
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String
        }
    }

    /// The pending tool row's spinner speaks "Running". Inside the row's button SwiftUI merges it into
    /// the button's label ("Shell, make test, Running"), as it did for `RunningSpinner`.
    private func isRunningElement(_ object: NSObject) -> Bool { texts(object).contains { $0.hasSuffix("Running") } }

    /// A group card's combined header label reads "..., Running", so the word is found anywhere in it.
    private func mentionsRunning(_ object: NSObject) -> Bool { texts(object).contains { $0.contains("Running") } }

    private func describe(_ objects: [NSObject]) -> String {
        objects.map { "\(type(of: $0))\(texts($0))" }.joined(separator: " | ")
    }

    private func awaitTree(_ mounted: Mounted, _ condition: @MainActor ([NSObject]) -> Bool) async {
        await waitUntil { condition(publishedObjects(mounted.cell)) }
    }

    @Test func givenStreamingRow_whenAccessibilityIsRead_thenTextIsPublishedAndNoCaretElementIs() async throws {
        // given
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, textEntry(1, streaming: true))
        await awaitTree(mounted) { $0.contains { texts($0).contains { $0.contains("hello world") } } }
        await waitUntil { animations(mounted) == 1 }
        // when
        let objects = publishedObjects(mounted.cell)
        // then: the check is not vacuous, and the caret exposes nothing.
        let summary = describe(objects)
        #expect(objects.contains { texts($0).contains { $0.contains("hello world") } }, "tree: \(summary)")
        #expect(!objects.contains { texts($0).contains { $0.contains("\u{258D}") } }, "tree: \(summary)")
        #expect(!objects.contains { $0 is LayerCaretView }, "tree: \(summary)")
        #expect(carets(mounted).allSatisfy { !$0.isAccessibilityElement() })
    }

    @Test func givenPendingToolRow_whenAccessibilityIsRead_thenOneElementIsLabelledRunning() async throws {
        for style in [ActivityFeedStyle.standard, .transcript] {
            // given
            let mounted = mount()
            defer { mounted.fixture.close() }
            configure(mounted, toolEntry(1, resolved: false), style: style)
            await awaitTree(mounted) { $0.contains { isRunningElement($0) } }
            await waitUntil { animations(mounted) == 1 }
            // when
            let objects = publishedObjects(mounted.cell)
            // then
            let running = objects.filter { isRunningElement($0) }
            #expect(running.count == 1, "\(style) tree: \(describe(objects))")
            #expect(!objects.contains { $0 is LayerSpinnerView }, "\(style)")
        }
    }

    @Test func givenLiveStepLine_whenAccessibilityIsRead_thenItIsOneCombinedElementWithoutADot() async throws {
        for style in [ActivityFeedStyle.standard, .transcript] {
            // given
            let mounted = mount()
            defer { mounted.fixture.close() }
            configure(mounted, liveStepEntry(), style: style)
            await awaitTree(mounted) { $0.contains { texts($0).contains { $0.contains("Thinking about the plan") } } }
            await waitUntil { animations(mounted) == 1 }
            // when
            let objects = publishedObjects(mounted.cell)
            // then
            let lines = objects.filter { texts($0).contains { $0.contains("Thinking about the plan") } }
            #expect(lines.count == 1, "\(style) tree: \(describe(objects))")
            #expect(!objects.contains { $0 is LayerPulseDotView || $0 is LayerSpinnerView }, "\(style)")
            #expect(!objects.contains { isRunningElement($0) }, "\(style): the glyph is hidden, not labelled")
            #expect((dots(mounted) + spinners(mounted)).allSatisfy { !$0.isAccessibilityElement() })
            // the combined element's own children carry no separate indicator element
            let children = (lines.first?.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any]) ?? []
            #expect(children.compactMap { $0 as? LayerMotionView }.isEmpty, "\(style)")
        }
    }

    @Test func givenRecycledCell_whenReconfigured_thenAccessibilityMatchesTheCurrentContent() async throws {
        // given: a streaming row, then the hidden sentinel, then a pending tool row, then streaming again
        let mounted = mount()
        defer { mounted.fixture.close() }
        configure(mounted, textEntry(1, streaming: true))
        await awaitTree(mounted) { $0.contains { texts($0).contains { $0.contains("hello world") } } }
        #expect(mounted.cell.isAccessibilityElement())
        // when
        configure(mounted, .bottom(topSpacing: 20))
        // then
        #expect(!mounted.cell.isAccessibilityElement())
        #expect(mounted.cell.accessibilityChildren()?.isEmpty == true)
        #expect(animations(mounted) == 0)
        // when
        configure(mounted, toolEntry(2, resolved: false))
        await awaitTree(mounted) { $0.contains { isRunningElement($0) } }
        await waitUntil { animations(mounted) == 1 }
        // then
        var objects = publishedObjects(mounted.cell)
        #expect(objects.filter { isRunningElement($0) }.count == 1, "tree: \(describe(objects))")
        #expect(!objects.contains { texts($0).contains { $0.contains("hello world") } })
        // when
        configure(mounted, textEntry(1, streaming: true))
        await awaitTree(mounted) { $0.contains { texts($0).contains { $0.contains("hello world") } } }
        await waitUntil { animations(mounted) == 1 && carets(mounted).count == 1 }
        // then
        objects = publishedObjects(mounted.cell)
        #expect(objects.contains { texts($0).contains { $0.contains("hello world") } }, "tree: \(describe(objects))")
        #expect(!objects.contains { texts($0).contains { $0.contains("\u{258D}") } })
        #expect(!objects.contains { isRunningElement($0) })
        #expect(!objects.contains { $0 is LayerCaretView })
        #expect(animations(mounted) == 1)
    }
}
