import AppKit
import HfUI
import SwiftUI

// MARK: - ComposerSizing

/// The approved M04 centered-composer metrics shared by the native editor and its SwiftUI placement.
/// Every visual line box is exactly `lineHeight` tall, framed by `verticalInset` above and below;
/// the `lineFragmentPadding` indents text and placeholder alike. One line measures `floorHeight`
/// (26), and `maximumLines` lines measure `capHeight` (136). These stay file-local: no shared
/// component metric changes with them.
enum ComposerSizing {
    /// Exact paragraph line height of one visual line, from the approved centered-composer design.
    static let lineHeight: CGFloat = 22
    /// Vertical text inset above the first line and below the last.
    static let verticalInset: CGFloat = HfRadius.Metrics.spacing2
    /// Native line-fragment padding: the horizontal text inset inside the text container.
    static let lineFragmentPadding: CGFloat = HfRadius.Metrics.spacing6
    /// The approved growth cap, counted in actual wrapped visual lines.
    static let maximumLines = 6

    /// The one-line floor: one line height plus the two vertical insets.
    static var floorHeight: CGFloat { lineHeight + 2 * verticalInset }
    /// The full growth cap: `maximumLines` line heights plus the two vertical insets.
    static var capHeight: CGFloat { CGFloat(maximumLines) * lineHeight + 2 * verticalInset }
}

// MARK: - ComposerPromptEditor

/// A literal prompt editor whose existing native text view becomes read-only while a start is
/// unresolved. The editor sizes itself from the text view's actual TextKit layout at the proposed
/// width — the same container width that renders — following real wrapped visual lines floored at
/// one and capped at the approved six; pure sizing never rewrites the string, resets the caret or
/// replaces the text view.
@MainActor
struct ComposerPromptEditor: NSViewRepresentable {
    @Binding var text: String
    let isLocked: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isLocked: isLocked) }

    func makeNSView(context: Context) -> ComposerPromptScrollView {
        let view = ComposerPromptScrollView()
        view.promptTextView.delegate = context.coordinator
        context.coordinator.owner = view
        return view
    }

    func updateNSView(_ view: ComposerPromptScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isLocked = isLocked
        let editor = view.promptTextView
        if editor.isEditable == isLocked {
            editor.undoManager?.removeAllActions()
            editor.allowsUndo = !isLocked
            editor.isEditable = !isLocked
        }
        if editor.string != text {
            editor.string = text
            view.reassertParagraphMetrics()
            view.needsLayout = true
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerPromptScrollView, context _: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.frameHeight(width: width))
    }

    static func dismantleNSView(_ view: ComposerPromptScrollView, coordinator _: Coordinator) {
        view.promptTextView.delegate = nil
        view.promptTextView.undoManager?.removeAllActions()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isLocked: Bool
        weak var owner: ComposerPromptScrollView?

        init(text: Binding<String>, isLocked: Bool) {
            self.text = text
            self.isLocked = isLocked
        }

        func textView(_: NSTextView, shouldChangeTextIn _: NSRange, replacementString _: String?) -> Bool {
            !isLocked
        }

        func textDidChange(_ notification: Notification) {
            guard !isLocked, let editor = notification.object as? NSTextView else { return }
            if text.wrappedValue != editor.string { text.wrappedValue = editor.string }
            owner?.needsLayout = true
            owner?.invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - ComposerPromptScrollView

@MainActor
final class ComposerPromptScrollView: NSScrollView {
    let promptTextView: NSTextView = ComposerPromptTextView(frame: .zero)
    /// Pins every paragraph's line box to exactly `ComposerSizing.lineHeight`, so layout,
    /// measurement, caret placement and scrolling all agree on the approved line grid.
    let paragraphMetrics: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = ComposerSizing.lineHeight
        style.maximumLineHeight = ComposerSizing.lineHeight
        return style
    }()

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        promptTextView.isEditable = true
        promptTextView.isSelectable = true
        promptTextView.isRichText = false
        promptTextView.importsGraphics = false
        promptTextView.allowsUndo = true
        promptTextView.drawsBackground = false
        promptTextView.font = NSFont.systemFont(ofSize: HfTextStyle.body.pointSize)
        promptTextView.textColor = .textColor
        promptTextView.defaultParagraphStyle = paragraphMetrics
        var typing = promptTextView.typingAttributes
        typing[.paragraphStyle] = paragraphMetrics
        promptTextView.typingAttributes = typing
        promptTextView.textContainerInset = NSSize(width: 0, height: ComposerSizing.verticalInset)
        promptTextView.textContainer?.lineFragmentPadding = ComposerSizing.lineFragmentPadding
        promptTextView.isHorizontallyResizable = false
        promptTextView.isVerticallyResizable = true
        promptTextView.autoresizingMask = [.width]
        promptTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Measurement and layout both set the exact clip/proposal width. Automatic tracking
        // would overwrite it from the text view's previous frame during TextKit layout.
        promptTextView.textContainer?.widthTracksTextView = false
        promptTextView.textContainer?.heightTracksTextView = false
        promptTextView.setAccessibilityLabel("Task prompt")
        documentView = promptTextView
    }

    required init?(coder _: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(promptTextView) ?? false
    }

    /// The editor frame's height at `width`: measured actual wrapped lines, floored at one and
    /// capped at `ComposerSizing.maximumLines`. Sizing and rendering share this exact entry point.
    func frameHeight(width: CGFloat) -> CGFloat {
        CGFloat(frameLines(width: width)) * ComposerSizing.lineHeight + 2 * ComposerSizing.verticalInset
    }

    /// The editor frame's visual line count at `width`, floored at one and capped at the approved six.
    func frameLines(width: CGFloat) -> Int {
        min(max(1, measuredLines(width: width)), ComposerSizing.maximumLines)
    }

    /// The actual wrapped visual lines at `width` before capping: real TextKit line fragments plus
    /// TextKit's extra insertion line after a trailing newline, floored at one combined total —
    /// an empty draft never counts its reserved insertion line twice. No character or break counting.
    func measuredLines(width: CGFloat) -> Int {
        measure(width: width).lines
    }

    /// The full uncapped document height at `width` — everything the capped scroll view can reveal.
    func documentHeight(width: CGFloat) -> CGFloat {
        max(ComposerSizing.floorHeight, measure(width: width).documentHeight)
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : max(1, contentView.bounds.width)
        return NSSize(width: width, height: frameHeight(width: width))
    }

    override func layout() {
        super.layout()
        let width = max(1, contentView.bounds.width)
        let height = max(contentView.bounds.height, documentHeight(width: width))
        let size = NSSize(width: width, height: height)
        if promptTextView.frame.size != size { promptTextView.setFrameSize(size) }
    }

    /// Re-applies the exact line-box paragraph style after programmatically set draft text.
    /// Attributes only — never rewrites the string or disturbs the selection.
    func reassertParagraphMetrics() {
        guard let storage = promptTextView.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: paragraphMetrics,
                             range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// One pass of the text view's own TextKit layout at `width` — the same layout that renders
    /// when the scroll view is `width` wide, because both use this width for the container.
    private func measure(width: CGFloat) -> (lines: Int, documentHeight: CGFloat) {
        guard width.isFinite, width > 0,
              let container = promptTextView.textContainer,
              let manager = promptTextView.layoutManager else {
            return (1, ComposerSizing.floorHeight)
        }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        var lines = 0
        var index = 0
        let glyphCount = manager.numberOfGlyphs
        while index < glyphCount {
            var fragment = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragment)
            guard fragment.length > 0 else { break }
            lines += 1
            index = NSMaxRange(fragment)
        }
        // TextKit keeps the caret's extra insertion line out of usedRect after a trailing newline.
        let insertionLine = manager.extraLineFragmentTextContainer === container ? 1 : 0
        var height = ceil(manager.usedRect(for: container).height)
        if insertionLine > 0 { height += ceil(manager.extraLineFragmentRect.height) }
        return (max(1, lines + insertionLine), height + 2 * ComposerSizing.verticalInset)
    }
}

// MARK: - ComposerPromptTextView

/// Prompt undo belongs to this editor, independently of other controls in the window.
@MainActor
private final class ComposerPromptTextView: NSTextView {
    private let promptUndoManager = UndoManager()
    override var undoManager: UndoManager? { promptUndoManager }
}

#if DEBUG
#Preview("Prompt editor") {
    ComposerPromptEditor(text: .constant("Describe the task."), isLocked: false)
        .frame(width: 480)
        .padding()
}
#endif
