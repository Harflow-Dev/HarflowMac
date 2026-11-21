import AppKit
import SwiftUI

// MARK: - WorkflowInspectorFiniteEdgeState

/// Decoration of the finite pane's existing native scroll. No additional scroll owner is created.
@MainActor
final class WorkflowInspectorFiniteEdgeState {
    private var edge: TaskComposerNativeEdge?
    private weak var scroll: NSScrollView?
    private weak var probe: NSView?
    private var enabled = false
    private var protectedFrames: [String: CGRect] = [:]
    private var protectedIDs: Set<String> = []
    private var attachment: Task<Void, Never>?

    func configure(enabled: Bool, protectedIDs: Set<String>, probe: NSView) {
        self.enabled = enabled
        self.protectedIDs = protectedIDs
        protectedFrames = protectedFrames.filter { protectedIDs.contains($0.key) }
        self.probe = probe
        if !enabled { stopDecoration(); return }
        attach(from: probe)
    }

    func attach(from probe: NSView) {
        attachment?.cancel()
        guard enabled, probe.window != nil else { stopDecoration(); return }
        attachment = Task { @MainActor [weak self, weak probe] in
            await Task.yield()
            guard !Task.isCancelled, let self, enabled, let probe,
                  probe.window != nil, let candidate = probe.enclosingScrollView,
                  candidate.documentView != nil, candidate.contentView.bounds.height > 0 else { return }
            if scroll !== candidate {
                stopDecoration()
                scroll = candidate
                let value = TaskComposerNativeEdge()
                value.install(in: candidate)
                value.actionOverlap = { [weak self] band in self?.overlapsActions(band) == true }
                edge = value
            }
            edge?.update(enabled: true, positioned: true)
        }
    }

    func reportFrame(id: String, frame: CGRect) {
        guard protectedIDs.isEmpty || protectedIDs.contains(id) else { return }
        protectedFrames[id] = frame
        edge?.update(enabled: enabled, positioned: scroll != nil)
    }

    private func overlapsActions(_ band: CGRect) -> Bool {
        guard let scroll, let document = scroll.documentView, let probe else { return false }
        let origin = document.convert(probe.bounds, from: probe).origin
        return protectedFrames.values.contains { frame in
            frame.offsetBy(dx: origin.x, dy: origin.y).intersects(band)
        }
    }

    private func stopDecoration() {
        edge?.stop()
        edge = nil
        scroll = nil
    }

    func stop() {
        attachment?.cancel()
        attachment = nil
        stopDecoration()
        protectedFrames.removeAll()
        probe = nil
    }
}

// MARK: - WorkflowInspectorFiniteEdgeProbe

struct WorkflowInspectorFiniteEdgeProbe: NSViewRepresentable {
    let state: WorkflowInspectorFiniteEdgeState
    let enabled: Bool
    let protectedIDs: Set<String>

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.state = state
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.state = state
        state.configure(enabled: enabled, protectedIDs: protectedIDs, probe: view)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.state?.stop() }

    final class Probe: NSView {
        weak var state: WorkflowInspectorFiniteEdgeState?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); state?.attach(from: self) }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); state?.attach(from: self) }
    }
}
