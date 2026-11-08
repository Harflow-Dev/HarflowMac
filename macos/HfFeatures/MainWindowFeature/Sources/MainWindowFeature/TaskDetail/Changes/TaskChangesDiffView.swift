//
//  TaskChangesDiffView.swift
//  MainWindowFeature
//
//  The Changes tab's diff block for the selected row (`diffBlock`, HarflowDesign 17739e4): a header with the path and
//  scope tag, mono lines in a bordered surface, and the states that stand in for them.
//

import AppKit
import SwiftUI

// MARK: - ChangesDiffView

/// The selected row's diff block (`diffBlock`): a header with the path and scope tag, then the lines or the state that
/// stands in for them.
struct ChangesDiffView: View {
    let diff: TaskChangesDiffPresentation
    let perform: (TaskChangesNote.Action) -> Void

    var body: some View {
        switch diff {
        case .none:
            EmptyView()
        case .loading(let header):
            ChangesDiffHead(header: header)
            ChangesNoteView(note: TaskChangesNote(tone: .neutral, title: "", skeletonBars: 2), perform: perform)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reading diff")
                .accessibilityAddTraits(.updatesFrequently)
            caption("Loading: the row stays selected and no text is implied.")
        case .noText(let header, let label):
            ChangesDiffHead(header: header)
            caption(label)
        case .diff(let model):
            ChangesDiffBlock(model: model)
        case .failure(let header, let note):
            if let header { ChangesDiffHead(header: header) }
            ChangesNoteView(note: note, perform: perform)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(TaskScreenStyle.sans(size: 12))
            .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - ChangesDiffHead

/// `.hd-m05-diffhead`: the path and a scope tag.
private struct ChangesDiffHead: View {
    let header: TaskChangesDiffHeader

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: header.path)
                .font(TaskScreenStyle.mono(size: TaskScreenStyle.ChangeRow.pathSize))
                .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            ChangesTagView(tag: TaskChangesTag(text: header.scope, tone: .neutral))
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - ChangesDiffBlock

/// `.hd-diff`: mono 12/19 lines in a bordered surface. The lines are one read-only, selectable text view that scrolls sideways
/// rather than wrapping, at its natural height up to a cap and then with its own vertical scrolling.
private struct ChangesDiffBlock: View {
    let model: TaskChangesDiffModel
    private static let maxHeight: CGFloat = 440

    /// With legacy (always visible) scrollers the horizontal one takes room from the lines; overlay scrollers take none.
    private static var scrollerExtra: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    var body: some View {
        ChangesDiffHead(header: model.header)
        ForEach([model.notice, model.lineEndingNotice].compactMap(\.self), id: \.self) { notice in
            ChangesTagView(tag: TaskChangesTag(text: notice, tone: .info))
        }
        let style = TaskScreenStyle.Diff.self
        ChangesDiffTextView(text: model.text, label: "Diff of \(model.header.path)")
            .frame(height: min(model.text.contentHeight + Self.scrollerExtra, Self.maxHeight))
            .background(style.fill.color)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: style.cornerRadius).stroke(style.borderColor.color, lineWidth: style.borderWidth))
        ForEach([model.tail, model.caption].compactMap(\.self), id: \.self) { text in
            Text(verbatim: text)
                .font(TaskScreenStyle.sans(size: 12))
                .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - ChangesDiffTextView

/// A TextKit 1 text view over the prebuilt attributed string. Only the visible lines are laid out and drawn, so a long
/// patch costs no more than a short one. Read-only and selectable; its accessibility label names the file, and each
/// added or removed line starts with its `+` or `-`.
private struct ChangesDiffTextView: NSViewRepresentable {
    let text: TaskChangesDiffText
    let label: String

    final class Coordinator {
        var identity: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = TaskScreenStyle.Diff.linePaddingHorizontal
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = DiffNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: TaskChangesDiffText.verticalInset)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.setAccessibilityLabel(label)
        (textView as? DiffNSTextView)?.syncMinimumWidth()
        guard context.coordinator.identity != text.identity else { return }
        context.coordinator.identity = text.identity
        textView.textStorage?.setAttributedString(text.attributed)
        textView.scroll(.zero)
    }
}

// MARK: - DiffNSTextView

/// Fills the whole width behind added, removed, hunk and header lines, for the lines in view only.
private final class DiffNSTextView: NSTextView {
    /// Keeps the view at least as wide as the clip view, so the fills span the block however short the longest line is.
    func syncMinimumWidth() {
        guard let width = enclosingScrollView?.contentSize.width, minSize.width != width else { return }
        minSize.width = width
        needsDisplay = true
    }

    override func layout() {
        syncMinimumWidth()
        super.layout()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let width = max(bounds.width, enclosingScrollView?.contentSize.width ?? 0)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, fragment, _ in
                let index = layoutManager.characterIndexForGlyph(at: fragment.location)
                guard index < storage.length,
                      let code = storage.attribute(TaskChangesDiffText.kindKey, at: index, effectiveRange: nil) as? Int,
                      let fill = TaskChangesDiffText.fills[code] else { return }
                fill.setFill()
                NSRect(x: 0, y: lineRect.minY + origin.y, width: width, height: lineRect.height).fill()
            }
        }
    }
}
