import AppKit
import Combine
import PbTestUtilities
@testable import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ScrollChromeScopeTests {
    @Test func givenExactSiblingMarkersAndDirectCandidate_whenDiscovering_thenCandidateIsOwned() {
        // given
        let (root, first, scroll, second) = bracketedScroll(wrapper: false)
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) === scroll)
        #expect(ScrollChromeScopeDiscovery.candidate(around: second) === scroll)
    }

    @Test func givenOneWrapperLevel_whenDiscovering_thenCandidateIsOwned() {
        // given
        let (root, first, scroll, second) = bracketedScroll(wrapper: true)
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) === scroll)
        #expect(ScrollChromeScopeDiscovery.candidate(around: second) === scroll)
    }

    @Test func givenDeepWrapperEndpoint_whenDiscovering_thenItFailsClosed() {
        // given
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let pairID = ScrollChromeScopePairID()
        let first = ScrollChromeScopeMarkerView(pairID: pairID)
        let second = ScrollChromeScopeMarkerView(pairID: pairID)
        let wrapper = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        let deepWrapper = NSView(frame: wrapper.bounds)
        let scroll = makeScroll()
        scroll.frame = deepWrapper.bounds
        deepWrapper.addSubview(scroll)
        wrapper.addSubview(deepWrapper)
        first.frame = wrapper.frame
        second.frame = wrapper.frame
        [first, wrapper, second]
.forEach(root.addSubview)
        // when
        let candidate = ScrollChromeScopeDiscovery.candidate(around: first)
        // then
        #expect(candidate == nil)
    }

    @Test func givenAmbiguousOrMismatchedScope_whenDiscovering_thenItFailsClosed() {
        // given
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let pairID = ScrollChromeScopePairID()
        let first = ScrollChromeScopeMarkerView(pairID: pairID)
        let second = ScrollChromeScopeMarkerView(pairID: pairID)
        let firstScroll = makeScroll()
        let secondScroll = makeScroll()
        first.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        second.frame = first.frame
        firstScroll.frame = first.frame
        secondScroll.frame = first.frame
        [first, firstScroll, secondScroll, second]
.forEach(root.addSubview)
        // when
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) == nil)

        let wrappedRoot = NSView(frame: root.frame)
        let wrappedFirst = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let wrappedSecond = ScrollChromeScopeMarkerView(pairID: wrappedFirst.pairID)
        let wrapper = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        let wrappedScrollA = makeScroll()
        let wrappedScrollB = makeScroll()
        wrappedScrollA.frame = wrapper.bounds
        wrappedScrollB.frame = wrapper.bounds
        wrapper.addSubview(wrappedScrollA)
        wrapper.addSubview(wrappedScrollB)
        wrappedFirst.frame = wrapper.frame
        wrappedSecond.frame = wrapper.frame
        [wrappedFirst, wrapper, wrappedSecond]
.forEach(wrappedRoot.addSubview)
        #expect(ScrollChromeScopeDiscovery.candidate(around: wrappedFirst) == nil)

        let mismatchedRoot = NSView(frame: root.frame)
        let mismatchedFirst = ScrollChromeScopeMarkerView(pairID: pairID)
        let mismatchedSecond = ScrollChromeScopeMarkerView(pairID: pairID)
        let mismatchedScroll = makeScroll()
        mismatchedFirst.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        mismatchedSecond.frame = mismatchedFirst.frame
        mismatchedScroll.frame = CGRect(x: 0, y: 0, width: 190, height: 150)
        [mismatchedFirst, mismatchedScroll, mismatchedSecond].forEach(mismatchedRoot.addSubview)
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: mismatchedFirst) == nil)
    }

    @Test func givenNativeFieldEditor_whenDiscovering_thenSharedEditorIsRejected() {
        // given
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let pairID = ScrollChromeScopePairID()
        let first = ScrollChromeScopeMarkerView(pairID: pairID)
        let second = ScrollChromeScopeMarkerView(pairID: pairID)
        let scroll = makeScroll()
        let editor = NSTextView(frame: scroll.bounds)
        editor.isFieldEditor = true
        scroll.documentView = editor
        first.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        second.frame = first.frame
        scroll.frame = first.frame
        [first, scroll, second]
.forEach(root.addSubview)
        // when / then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) == nil)
    }

    @Test func givenNativeTextFieldWithoutDedicatedScrollView_whenScoped_thenItIsAQuietNoOp() async throws {
        // given
        let model = ScopeFixtureModel()
        let fixture = makeHost(ScopeTextFieldFixture(model: model))
        let host = fixture.host
        defer { fixture.close() }
        await waitUntil(timeout: 5) { descendants(host).compactMap { $0 as? ScrollChromeScopeMarkerView }.count >= 2 }
        // when
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first)
        let markers = descendants(host).compactMap { $0 as? ScrollChromeScopeMarkerView }
        // then
        #expect(enclosingScrollView(field) == nil)
        #expect(!markers.isEmpty)
        #expect(markers.allSatisfy { ScrollChromeScopeDiscovery.candidate(around: $0) == nil })
    }

    @Test func givenNestedTextEditorAndOuterScrollView_whenHosted_thenScopeFindsInnerOnly() async throws {
        // given
        let model = ScopeFixtureModel()
        let fixture = makeHost(NestedEditorFixture(model: model))
        let host = fixture.host
        defer { fixture.close() }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            let markers = descendants(host).compactMap { $0 as? ScrollChromeScopeMarkerView }
            let editorScrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter {
                guard let editor = $0.documentView as? NSTextView else { return false }
                return !editor.isFieldEditor
            }
            return markers.count >= 2 && editorScrolls.count == 1 && uniqueCandidate(in: host) != nil
        }
        // when
        let markers = descendants(host).compactMap { $0 as? ScrollChromeScopeMarkerView }
        let candidates = Set(markers.compactMap { ScrollChromeScopeDiscovery.candidate(around: $0).map(ObjectIdentifier.init) })
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        let editorScrolls = scrolls.filter {
            guard let editor = $0.documentView as? NSTextView else { return false }
            return !editor.isFieldEditor
        }
        try #require(markers.count >= 2)
        try #require(editorScrolls.count == 1)
        let editorScroll = try #require(editorScrolls.first)
        let outerScroll = try #require(scrolls.first { $0 !== editorScroll })
        // then
        if candidates.count != 1 { printNativeHierarchy(host, label: "nested-editor") }
        #expect(candidates.count == 1)
        #expect(candidates.contains(ObjectIdentifier(editorScroll)))
        #expect(!candidates.contains(ObjectIdentifier(outerScroll)))
        assertChrome(editorScroll)
    }

    @Test func givenScopedList_whenRowsBecomeEmptyPopulatedAndEmpty_thenContainerCandidateRemainsStable() async throws {
        // given
        let model = ScopeFixtureModel()
        let fixture = makeHost(ScopedListFixture(model: model))
        let host = fixture.host
        defer { fixture.close() }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return uniqueCandidate(in: host) != nil
        }
        if uniqueCandidate(in: host) == nil { printNativeHierarchy(host, label: "list-empty") }
        let initial = try #require(uniqueCandidate(in: host))
        let initialScroll = try #require(scroll(in: host, identifier: initial))
        assertChrome(initialScroll)
        // when
        model.rows = Array(0 ..< 40)
        await waitUntil(timeout: 5) {
            guard let identifier = uniqueCandidate(in: host),
                  let candidate = scroll(in: host, identifier: identifier),
                  let document = candidate.documentView
            else { return false }
            return document.bounds.height > candidate.contentView.bounds.height
        }
        let populated = try #require(uniqueCandidate(in: host))
        let populatedScroll = try #require(scroll(in: host, identifier: populated))
        let bottom = max(0, populatedScroll.documentView!.bounds.height - populatedScroll.contentView.bounds.height)
        populatedScroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        populatedScroll.reflectScrolledClipView(populatedScroll.contentView)
        assertChrome(populatedScroll)
        model.rows = Array(100 ..< 160)
        await waitUntil(timeout: 5) {
            guard let identifier = uniqueCandidate(in: host),
                  let candidate = scroll(in: host, identifier: identifier),
                  let document = candidate.documentView
            else { return false }
            return document.bounds.height > candidate.contentView.bounds.height
        }
        let replaced = try #require(uniqueCandidate(in: host))
        let replacedScroll = try #require(scroll(in: host, identifier: replaced))
        assertChrome(replacedScroll)
        model.rows = []
        await waitUntil(timeout: 5) { uniqueCandidate(in: host) != nil }
        let emptied = try #require(uniqueCandidate(in: host))
        // then
        let emptiedScroll = try #require(scroll(in: host, identifier: emptied))
        assertChrome(emptiedScroll)
        #expect(initial == populated)
        #expect(populated == replaced)
        #expect(replaced == emptied)
    }

    @Test func givenShortForm_whenHosted_thenItRemainsAQuietNoOpWithoutScopedTarget() async throws {
        // given
        let model = ScopeFixtureModel()
        let fixture = makeHost(ScopedFormFixture(model: model))
        let host = fixture.host
        defer { fixture.close() }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? ScrollChromeScopeMarkerView }.count >= 2
        }
        // when
        let candidate = uniqueCandidate(in: host)
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        // then
        #expect(candidate == nil)
        #expect(scrolls.allSatisfy { $0.scrollerStyle != .overlay })
    }

    @Test func givenLongGroupedForm_whenHosted_thenItsActualContainerGetsNativeChrome() async throws {
        // given
        let model = ScopeFixtureModel()
        let fixture = makeHost(ScopedGroupedLongFormFixture(model: model))
        let host = fixture.host
        defer { fixture.close() }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return uniqueCandidate(in: host) != nil
        }
        if uniqueCandidate(in: host) == nil { printNativeHierarchy(host, label: "grouped-long-form") }
        // when
        let candidate = try #require(uniqueCandidate(in: host))
        let scrollView = try #require(scroll(in: host, identifier: candidate))
        // then
        assertChrome(scrollView)
        #expect(scrollView.hasVerticalScroller || scrollView.hasHorizontalScroller)
    }

    @Test func givenMultilineVerticalTextField_whenIdleAndEditing_thenDedicatedChromeIsScopedOrQuiet() async throws {
        // given
        let model = ScopeFixtureModel()
        let fixture = makeHost(MultilineTextFieldFixture(model: model))
        let host = fixture.host
        defer { fixture.close() }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? ScrollChromeScopeMarkerView }.count >= 2
        }
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first)
        let before = chromeSnapshot(in: host)
        // when
        let idleCandidate = uniqueCandidate(in: host)
        let editing = host.window?.makeFirstResponder(field) ?? false
        await waitUntil(timeout: 2) { field.currentEditor() != nil || !editing }
        let editingCandidate = uniqueCandidate(in: host)
        // then
        #expect(editing || field.currentEditor() != nil)
        #expect(idleCandidate == editingCandidate)
        if let identifier = editingCandidate {
            let scrollView = try #require(scroll(in: host, identifier: identifier))
            assertChrome(scrollView)
        } else {
            #expect(enclosingScrollView(field) == nil)
            #expect(chromeSnapshot(in: host) == before)
        }
    }

    private func bracketedScroll(wrapper: Bool) -> (NSView, ScrollChromeScopeMarkerView, NSScrollView, ScrollChromeScopeMarkerView) {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let pairID = ScrollChromeScopePairID()
        let first = ScrollChromeScopeMarkerView(pairID: pairID)
        let second = ScrollChromeScopeMarkerView(pairID: pairID)
        let scroll = makeScroll()
        let frame = CGRect(x: 20, y: 20, width: 200, height: 150)
        first.frame = frame
        second.frame = frame
        if wrapper {
            let container = NSView(frame: frame)
            scroll.frame = container.bounds
            container.addSubview(scroll)
            [first, container, second].forEach(root.addSubview)
        } else {
            scroll.frame = frame
            [first, scroll, second].forEach(root.addSubview)
        }
        return (root, first, scroll, second)
    }

    private func makeScroll() -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        return scroll
    }

    private func uniqueCandidate(in host: NSView) -> ObjectIdentifier? {
        let values = Set(descendants(host).compactMap { view in
            (view as? ScrollChromeScopeMarkerView).flatMap { ScrollChromeScopeDiscovery.candidate(around: $0) }.map(ObjectIdentifier.init)
        })
        return values.count == 1 ? values.first : nil
    }

    private func scroll(in host: NSView, identifier: ObjectIdentifier) -> NSScrollView? {
        descendants(host).compactMap { $0 as? NSScrollView }.first { ObjectIdentifier($0) == identifier }
    }

    private func enclosingScrollView(_ view: NSView) -> NSScrollView? {
        var current = view.superview
        while let view = current {
            if let scroll = view as? NSScrollView { return scroll }
            current = view.superview
        }
        return nil
    }

    private func assertChrome(_ scroll: NSScrollView) {
        #expect(scroll.scrollerStyle == .overlay)
        if scroll.hasVerticalScroller { #expect(scroll.verticalScroller?.controlSize == .small) }
        if scroll.hasHorizontalScroller { #expect(scroll.horizontalScroller?.controlSize == .small) }
    }

    private func chromeSnapshot(in host: NSView) -> [ChromeState] {
        descendants(host).compactMap { $0 as? NSScrollView }.map {
            ChromeState(
                style: $0.scrollerStyle,
                verticalSize: $0.verticalScroller?.controlSize,
                horizontalSize: $0.horizontalScroller?.controlSize
            )
        }
    }

    private func makeHost<Content: View>(_ view: Content) -> HostedFixture<Content> {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 260)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return HostedFixture(host: host, window: window)
    }

    private func printNativeHierarchy(_ host: NSView, label: String) {
        print("ScrollChromeScope diagnostic \(label)")
        for (index, view) in descendants(host).prefix(80).enumerated() {
            let parent = view.superview.map { String(describing: type(of: $0)) } ?? "nil"
            let markers = view as? ScrollChromeScopeMarkerView
            let sibling = view.superview?.subviews.firstIndex(of: view).map(String.init) ?? "nil"
            let description = "[\(index)] \(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) "
                + "parent=\(parent) sibling=\(sibling) marker=\(markers != nil)"
            print(description)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private struct ChromeState: Equatable {
    let style: NSScroller.Style
    let verticalSize: NSControl.ControlSize?
    let horizontalSize: NSControl.ControlSize?
}

@MainActor private struct HostedFixture<Content: View> {
    let host: NSHostingView<Content>
    let window: NSWindow

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor private final class ScopeFixtureModel: ObservableObject {
    @Published var rows: [Int] = []
    @Published var text = String(repeating: "Multiline instruction content. ", count: 80)
}

@MainActor private struct ScopeTextFieldFixture: View {
    @ObservedObject var model: ScopeFixtureModel

    var body: some View {
        TextField("Name", text: .constant("")).scrollChromeScope()
    }
}

@MainActor private struct NestedEditorFixture: View {
    @ObservedObject var model: ScopeFixtureModel

    var body: some View {
        ScrollView {
            TextEditor(text: .constant(String(repeating: "Nested editor content ", count: 40)))
                .scrollChromeScope()
                .frame(height: 180)
        }
    }
}

@MainActor private struct ScopedListFixture: View {
    @ObservedObject var model: ScopeFixtureModel

    var body: some View {
        List(model.rows, id: \.self) { row in
            Text("Row \(row)")
        }
        .scrollChromeScope()
    }
}

@MainActor private struct ScopedFormFixture: View {
    @ObservedObject var model: ScopeFixtureModel

    var body: some View {
        Form {
            TextField("Name", text: .constant("fixture"))
            Toggle("Enabled", isOn: .constant(true))
        }
        .scrollChromeScope()
    }
}

@MainActor private struct ScopedGroupedLongFormFixture: View {
    @ObservedObject var model: ScopeFixtureModel

    var body: some View {
        Form {
            ForEach(0 ..< 40, id: \.self) { row in
                TextField("Field \(row)", text: .constant("Long form value"))
            }
        }
        .formStyle(.grouped)
        .scrollChromeScope()
    }
}

@MainActor private struct MultilineTextFieldFixture: View {
    @ObservedObject var model: ScopeFixtureModel

    var body: some View {
        TextField("Instructions", text: $model.text, axis: .vertical)
            .lineLimit(10)
            .frame(height: 140)
            .scrollChromeScope()
    }
}
