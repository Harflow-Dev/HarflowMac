import AppKit
import SwiftUI

// MARK: - WorkflowRunSplitPosition

/// AppKit may re-propose a pane's intrinsic width when skeleton content is replaced.
/// Retain the last laid-out dividers across that one transition, including user resizing.
struct WorkflowRunSplitPosition: NSViewRepresentable {
    let isLoading: Bool
    let snapshot: WorkflowRunSplitSnapshot

    func makeNSView(context _: Context) -> WorkflowRunSplitProbe {
        WorkflowRunSplitProbe(snapshot: snapshot)
    }

    func updateNSView(_ view: WorkflowRunSplitProbe, context _: Context) {
        snapshot.update(isLoading: isLoading)
    }
}

// MARK: - WorkflowRunSplitSnapshot

/// Owned by the pane shell because SwiftUI can recreate a pane's platform background view.
@MainActor
final class WorkflowRunSplitSnapshot {
    var isLoading: Bool?
    var restoring = false
    var inspectorWidth: CGFloat?
    var canvasHeight: CGFloat?
    weak var inspectorSplit: NSSplitView?
    weak var canvasSplit: NSSplitView?

    func update(isLoading: Bool) {
        defer { self.isLoading = isLoading }
        guard let previous = self.isLoading, previous != isLoading, let inspectorWidth else { return }
        restoring = true
        let canvasHeight = canvasHeight
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let split = inspectorSplit {
                split.setPosition(split.bounds.width - inspectorWidth - split.dividerThickness, ofDividerAt: 0)
            }
            if let split = canvasSplit, let canvasHeight {
                split.setPosition(canvasHeight, ofDividerAt: 0)
            }
            restoring = false
        }
    }
}

// MARK: - WorkflowRunSplitProbe

final class WorkflowRunSplitProbe: NSView {
    private let snapshot: WorkflowRunSplitSnapshot

    init(snapshot: WorkflowRunSplitSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard !snapshot.restoring else { return }
        for split in ancestorSplits() where split.arrangedSubviews.count == 2 {
            if split.isVertical {
                snapshot.inspectorSplit = split
                snapshot.inspectorWidth = split.arrangedSubviews[1].frame.width
            } else {
                snapshot.canvasSplit = split
                snapshot.canvasHeight = split.arrangedSubviews[0].frame.height
            }
        }
    }

    private func ancestorSplits() -> [NSSplitView] {
        var result: [NSSplitView] = []
        var view = superview
        while let ancestor = view {
            if let split = ancestor as? NSSplitView {
                result.append(split)
                // The next split is either the graph's horizontal split or the app's navigation split.
                var parent = split.superview
                while let candidate = parent {
                    if let next = candidate as? NSSplitView {
                        if !next.isVertical { result.append(next) }
                        return result
                    }
                    parent = candidate.superview
                }
                return result
            }
            view = ancestor.superview
        }
        return result
    }
}
