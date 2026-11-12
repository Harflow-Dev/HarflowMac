import AppKit
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - ObservationActionLayout

/// Adjacent observation actions wrap while retaining the approved eight point gap.
struct ObservationActionLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        var maximum: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += height + 8; height = 0 }
            points.append(CGPoint(x: x, y: y))
            maximum = max(maximum, x + size.width)
            x += size.width + 8
            height = max(height, size.height)
        }
        return (CGSize(width: min(width, maximum), height: y + height), points)
    }
}

// MARK: - StoredRequestView

struct StoredRequestView: View {
    let state: TaskRequestReadState
    let read: (Int) -> Void
    let copy: (String) -> Void
    @State private var expanded: Bool
    @State private var textFocusIntent: StoredRequestFocusIntent?
    @State private var focusReplacement = false

    /// `initiallyExpanded` opens the disclosure on first draw (a Parallel lane's View prompt); the task screen keeps it closed.
    init(state: TaskRequestReadState, read: @escaping (Int) -> Void, copy: @escaping (String) -> Void, initiallyExpanded: Bool = false) {
        self.state = state
        self.read = read
        self.copy = copy
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                switch state {
                case .notRequested, .loading:
                    Text("Loading stored request")
                case let .failed(error, maxBytes):
                    Text(error.message)
                    Button("Retry request read") { readRequest(maxBytes) }
                case let .received(result, maxBytes):
                    received(result, maxBytes: maxBytes)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(heading).font(.hf(.secondary, weight: .semibold))
        }
        .onChange(of: state) { _, value in
            switch value {
            case .loading:
                cancelTextFocus()
            case .notRequested, .failed:
                focusReplacement = false
                cancelTextFocus()
            case .received:
                guard StoredRequestPresentation(state: value).text != nil else {
                    focusReplacement = false
                    cancelTextFocus()
                    return
                }
                if focusReplacement {
                    focusReplacement = false
                    cancelTextFocus()
                    textFocusIntent = StoredRequestFocusIntent()
                }
            }
        }
        .onChange(of: expanded) { _, value in
            if !value { focusReplacement = false; cancelTextFocus() }
        }
        .onDisappear { focusReplacement = false; cancelTextFocus() }
    }

    private func cancelTextFocus() {
        textFocusIntent?.cancel()
        textFocusIntent = nil
    }

    private var presentation: StoredRequestPresentation { StoredRequestPresentation(state: state) }
    private var heading: String { presentation.heading }

    private func full(_: TaskPromptResult) -> Bool { presentation.isFull }

    private func readRequest(_ maxBytes: Int) {
        ObservationAnnouncement.requested("Reading stored request")
        read(maxBytes)
    }

    @ViewBuilder private func received(_ value: TaskPromptResult, maxBytes: Int) -> some View {
        if value.state == .integrityFailed || value.integrity == .failed {
            Text("Questionable request text is withheld.")
            Button("Retry request read") { readRequest(65536) }
        } else if let text = value.text, value.state != .unavailable {
            Text(presentation.provenance ?? "")
                .font(.hf(.caption))
.foregroundStyle(.secondary)
            StoredRequestText(text: text, focusIntent: textFocusIntent) { consumed in
                if textFocusIntent === consumed { textFocusIntent = nil }
            }.frame(maxHeight: 180)
            ObservationActionLayout {
                Button(presentation.copyLabel ?? "Copy displayed text") { copy(text) }
                if let bound = presentation.readMoreBytes {
                    Button("Read more") { focusReplacement = true; readRequest(bound) }
                }
            }
            if !full(value), maxBytes >= 131072 {
                Text("This view's request limit has been reached. The full request is unavailable in this view.")
                    .font(.hf(.caption))
.foregroundStyle(.secondary)
            }
        } else {
            Text("The stored request is unavailable through the selected engine.")
            Button("Retry request read") { readRequest(65536) }
        }
    }
}

// MARK: - ObservationHistoryView

struct ObservationHistoryView: View {
    let frame: EventObservationFrame
    let action: (EventObservationAction) -> Void
    @FocusState private var boundaryFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status)
.font(.hf(.secondary))
.fixedSize(horizontal: false, vertical: true)
                .focusable()
.focused($boundaryFocused)
            if !frame.history.reasons.isEmpty {
                Text(frame.history.reasons.map(\.presentationText).sorted().joined(separator: " · "))
                    .font(.hf(.caption))
.foregroundStyle(.secondary)
            }
            if let failure = frame.history.failure {
                Text(failure.message).font(.hf(.caption)).textSelection(.enabled)
            }
            ObservationActionLayout {
                ForEach(actions, id: \.self) { value in
                    Button(label(value)) {
                        ObservationAnnouncement.requested(label(value))
                        action(value)
                        boundaryFocused = true
                    }.disabled(frame.history.isLoading)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: [EventObservationAction] {
        [.loadEarlier, .retryRead, .rebaseWindow, .adoptCurrentSource].filter { frame.history.availableActions.contains($0) }
    }

    private var status: String {
        if frame.history.currentness == .sourceChangePending { return "Activity source changed · cached history is not current" }
        if frame.history.currentness == .reconnecting {
            return frame.records.isEmpty ? "Captured history unavailable" : "Reconnecting · cached history is not current"
        }
        if frame.history.reasons.contains(.capacity) { return "This view's activity limit has been reached. Retained rows and reading position are preserved." }
        if frame.history.isLoading { return "Loading captured history" }
        if !frame.history.reasons.isEmpty { return "History incomplete or unavailable · see Events" }
        if frame.history.caughtUp { return "Captured activity caught up" }
        return "Available captured history · bounded window"
    }

    private func label(_ value: EventObservationAction) -> String {
        switch value {
        case .loadEarlier: "Load earlier"
        case .retryRead: "Retry history read"
        case .rebaseWindow: "Load current activity"
        case .adoptCurrentSource: "Load current activity from new source"
        }
    }
}

// MARK: - PublicEventsView

struct PublicEventsView: View {
    let frame: EventObservationFrame?
    let recovered: RecoveredTranscriptFrame
    let copy: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Public normalized events · bounded record window").font(.hf(.secondary, weight: .semibold))
            if let frame {
                if frame.summary.state == .observed, let counts = frame.summary.counts {
                    Text(counts.toolCalls == 0 ? "No tool calls observed in the available captured history"
                         : "\(counts.toolCalls) tool calls observed · \(counts.edits) edits · \(counts.commands) commands")
                } else {
                    Text(frame.summary.state == .loading ? "Loading tool activity" : "Tool activity unavailable")
                }
                ForEach(frame.records) { observed in
                    let json = observed.normalizedJSON
                    DisclosureGroup {
                        Text(verbatim: json).font(.hf(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy normalized record") { copy(json) }
                    } label: {
                        Text(observed.record.raw["kind"]?.stringValue ?? "Unsupported normalized record")
                            .font(.hf(.secondary))
                    }
                }
            } else { Text("Loading captured records") }
            if !recovered.items.isEmpty {
                Divider()
                Text("Recovered transcript").font(.hf(.secondary, weight: .semibold))
                Text("Display-only recovered material · excluded from captured activity facts").font(.hf(.caption))
                ForEach(recovered.events) { event in
                    Text(verbatim: event.rawLine).font(.hf(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ObservationAnnouncement

/// Explicit read actions announce once; polling publications never call this boundary.
@MainActor private enum ObservationAnnouncement {
    static func requested(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

#if DEBUG
#Preview("Original request · synthetic stored text") {
    StoredRequestView(state: TaskDetailViewModelMock.previewRequest(), read: { _ in }, copy: { _ in })
        .padding(16)
.frame(width: 480)
}

#Preview("History · observed synthetic window") {
    ObservationHistoryView(frame: TaskDetailViewModelMock.previewObservation(), action: { _ in })
        .padding(16)
.frame(width: 480)
}

#Preview("Events · public normalized synthetic record") {
    ScrollView {
        PublicEventsView(frame: TaskDetailViewModelMock.previewObservation(), recovered: .init(), copy: { _ in })
            .padding(16)
    }.frame(width: 320, height: 420)
}

#Preview("Wrapping observation actions") {
    ObservationActionLayout {
        Button("Load earlier") {}
        Button("New activity · show") {}
        Button("Retry history read") {}
    }
.padding(16)
.frame(width: 240)
}
#endif
