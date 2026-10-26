import SwiftUI

// MARK: - SkeletonContentState

/// Retains the once-only loading handoff across conditional mounts of the same selection.
@MainActor
@Observable
public final class SkeletonContentState {
    enum Phase: Equatable {
        case loading, prepared, revealing, resolved
    }

    private(set) var phase: Phase = .loading
    private(set) var hasRevealed = false
    private(set) var hasObservedLoading = false
    private var generation = 0
    @ObservationIgnored private let waitForPresentedFrame: @MainActor () async -> Void

    /// Creates a selection's handoff; an initially ready result bypasses loading motion.
    /// Leave `isLoading` nil for externally retained state before its first mounted presentation.
    public init(isLoading: Bool? = nil, waitForPresentedFrame: @escaping @MainActor () async -> Void = DisplayFrames.waitForPresentedFrame) {
        self.waitForPresentedFrame = waitForPresentedFrame
        self.hasObservedLoading = isLoading == true
        if isLoading == false {
            self.phase = .resolved
            self.hasRevealed = true
        }
    }

    func observeLoading() {
        hasObservedLoading = true
        invalidate()
    }

    func resolveInitiallyReady() {
        guard !hasObservedLoading, !hasRevealed else { return }
        hasRevealed = true
        phase = .resolved
    }

    func waitForPreparationFrame() async {
        await waitForPresentedFrame()
    }

    func prepare() -> Int {
        generation += 1
        if !hasRevealed { phase = .prepared }
        return generation
    }

    func reveal(generation: Int, immediately: Bool) {
        guard self.generation == generation else { return }
        hasRevealed = true
        phase = immediately ? .resolved : .revealing
    }

    func finish(generation: Int) {
        guard self.generation == generation, phase == .revealing else { return }
        phase = .resolved
    }

    func invalidate() {
        generation += 1
        phase = hasRevealed ? .resolved : .loading
    }
}

// MARK: - SkeletonContent

/// Lazily prepares a result, then crossfades its decorative skeleton once per retained identity.
/// The result owns layout from preparation onward; retiring the overlay cannot change its size.
public struct SkeletonContent<Placeholder: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.hfSkeletonHandoffActive) private var ancestorHandoffActive
    @State private var localState: SkeletonContentState
    private let retainedState: SkeletonContentState?
    private let isLoading: Bool
    private let placeholder: () -> Placeholder
    private let content: () -> Content

    /// Supply `state` when a selection can leave and reenter the view hierarchy without resetting.
    public init(
        isLoading: Bool,
        state: SkeletonContentState? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isLoading = isLoading
        _localState = State(initialValue: SkeletonContentState(isLoading: isLoading))
        self.retainedState = state
        self.placeholder = placeholder
        self.content = content
    }

    private var state: SkeletonContentState { retainedState ?? localState }
    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    public var body: some View {
        ZStack {
            if isLoading || (state.phase == .loading && state.hasObservedLoading) {
                decorativePlaceholder
            } else {
                content()
                    .opacity(state.phase == .prepared ? 0 : 1)
                    .allowsHitTesting(state.phase != .prepared)
                    .accessibilityHidden(state.phase == .prepared)
                    .environment(\.hfSkeletonHandoffActive, ancestorHandoffActive || state.phase != .resolved)
                    .overlay(alignment: .topLeading) {
                        if state.phase == .prepared || state.phase == .revealing {
                            decorativePlaceholder
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .clipped()
                                .environment(\.hfSkeletonPlaceholderOverlay, true)
                                .opacity(state.phase == .prepared ? 1 : 0)
                        }
                    }
            }
        }
        .onDisappear { state.invalidate() }
        .task(id: isLoading) {
            guard !isLoading else {
                state.observeLoading()
                return
            }
            state.resolveInitiallyReady()
            guard !state.hasRevealed else { return }
            let generation = state.prepare()
            if reduceMotion || ancestorHandoffActive {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { state.reveal(generation: generation, immediately: true) }
                return
            }
            // The transparent result must have its own committed layout before either opacity moves.
            await state.waitForPreparationFrame()
            guard !Task.isCancelled else { return }
            withAnimation(HfMotion.arrival, completionCriteria: .removed) {
                state.reveal(generation: generation, immediately: false)
            } completion: {
                state.finish(generation: generation)
            }
        }
    }

    private var decorativePlaceholder: some View {
        placeholder()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

public extension EnvironmentValues {
    /// Suppresses descendant arrival effects while an ancestor owns the visible handoff.
    @Entry var hfSkeletonHandoffActive = false

    /// Identifies the outgoing visual placeholder; native chrome must have only one owner.
    @Entry var hfSkeletonPlaceholderOverlay = false
}

#if DEBUG
private struct SkeletonHandoffPreview: View {
    @State private var isLoading = true
    @State private var replay = 0

    var body: some View {
        VStack {
            SkeletonContent(isLoading: isLoading) { SkeletonRows(count: 4) } content: {
                Text("Resolved content").font(.hf(.headline))
            }
            .id(replay)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Replay loading") { isLoading = true; replay += 1 }
        }
        .padding()
.frame(width: 320, height: 180)
        .task(id: replay) {
            await DisplayFrames.waitForPresentedFrame()
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }
}

#Preview("Skeleton handoff — light") {
    SkeletonHandoffPreview().preferredColorScheme(.light)
}

#Preview("Skeleton handoff — dark") {
    SkeletonHandoffPreview().preferredColorScheme(.dark)
}

#Preview("Skeleton handoff — reduced motion") {
    SkeletonHandoffPreview().environment(\.hfReduceMotionOverride, true)
}
#endif
