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
    var retryFocus: FocusState<ChangesFocus?>.Binding?
    var selection: TaskChangesSelection?

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
            if note.action == .retryDiff, let retryFocus, let selection {
                ChangesNoteView(note: note, perform: perform, retryFocus: retryFocus, selection: selection)
            } else {
                ChangesNoteView(note: note, perform: perform)
            }
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

/// Mono lines in a bordered, selectable text view sized to the wrapped document.
private struct ChangesDiffBlock: View {
    let model: TaskChangesDiffModel
    var body: some View {
        ChangesDiffHead(header: model.header)
        ForEach([model.notice, model.lineEndingNotice].compactMap(\.self), id: \.self) { notice in
            ChangesTagView(tag: TaskChangesTag(text: notice, tone: .info))
        }
        let style = TaskScreenStyle.Diff.self
        ChangesDiffTextView(text: model.text, label: "Diff of \(model.header.path)")
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

/// A width-tracking TextKit 1 document, measured once per patch and width. It remains selectable and read-only.
private struct ChangesDiffTextView: NSViewRepresentable {
    let text: TaskChangesDiffText
    let label: String

    final class Coordinator {
        var displayIdentity: Int?
        var measurementIdentity: Int?
        var heights: [CGFloat: CGFloat] = [:]
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

        init() {
            container.lineFragmentPadding = TaskScreenStyle.Diff.linePaddingHorizontal
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffNSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = TaskScreenStyle.Diff.linePaddingHorizontal
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = DiffNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: TaskChangesDiffText.verticalInset)
        return view
    }

    func updateNSView(_ view: DiffNSTextView, context: Context) {
        view.setAccessibilityLabel(label)
        guard context.coordinator.displayIdentity != text.identity else { return }
        context.coordinator.displayIdentity = text.identity
        view.textStorage?.setAttributedString(text.attributed)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let coordinator = context.coordinator
        if coordinator.measurementIdentity != text.identity {
            coordinator.measurementIdentity = text.identity
            coordinator.heights.removeAll()
            coordinator.storage.setAttributedString(text.attributed)
        }
        if let height = coordinator.heights[width] { return CGSize(width: width, height: height) }
        coordinator.container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        coordinator.layout.ensureLayout(for: coordinator.container)
        let height = ceil(coordinator.layout.usedRect(for: coordinator.container).maxY + 2 * TaskChangesDiffText.verticalInset)
        if coordinator.heights.count >= 4 { coordinator.heights.removeAll() }
        coordinator.heights[width] = height
        return CGSize(width: width, height: height)
    }
}

// MARK: - DiffNSTextView

/// Fills the whole width behind added, removed, hunk and header lines, for the lines in view only.
private final class DiffNSTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let width = bounds.width
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
