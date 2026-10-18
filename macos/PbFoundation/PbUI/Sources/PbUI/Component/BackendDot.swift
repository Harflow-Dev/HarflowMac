import SwiftUI

// MARK: - BackendDot

/// A small coloured dot identifying a backend. Decorative: pair it with a name (`BackendLabel`) or
/// give the container an accessibility label (`BackendDotStack`).
public struct BackendDot: View {
    public let backend: String
    public var size: CGFloat

    public init(backend: String, size: CGFloat = PbRadius.Metrics.backendDotSize) {
        self.backend = backend
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(BackendStyle.dotColor(backend))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - BackendLabel

/// "● Vibe": the backend's dot followed by its capitalised name. An unknown backend gets the
/// neutral dot and its own name, capitalised.
public struct BackendLabel: View {
    public let backend: String

    public init(backend: String) {
        self.backend = backend
    }

    public var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing5) {
            BackendDot(backend: backend)
            Text(BackendStyle.displayName(backend))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - BackendDotStack

/// Overlapping backend dots for a group of tasks. The accessibility label lists the backends.
public struct BackendDotStack: View {
    public let backends: [String]
    public var size: CGFloat

    public init(backends: [String], size: CGFloat = PbRadius.Metrics.backendDotStackSize) {
        self.backends = backends
        self.size = size
    }

    /// The spoken description: the distinct backends, in order of first appearance.
    public nonisolated static func accessibilityText(for backends: [String]) -> String {
        var seen: Set<String> = []
        let names = backends.filter { seen.insert($0).inserted }.map(BackendStyle.displayName)
        return names.joined(separator: ", ")
    }

    public var body: some View {
        HStack(spacing: -size * PbRadius.Metrics.backendDotStackOverlap) {
            ForEach(Array(backends.enumerated()), id: \.offset) { _, backend in
                BackendDot(backend: backend, size: size)
                    .overlay(Circle().stroke(Color.windowBG, lineWidth: PbRadius.Metrics.backendDotStackStroke))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(for: backends))
    }
}

#if DEBUG
#Preview("Backend dots - light") {
    BackendDotsPreview().preferredColorScheme(.light)
}

#Preview("Backend dots - dark") {
    BackendDotsPreview().preferredColorScheme(.dark)
}

private struct BackendDotsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            ForEach(BackendStyle.known + ["mystery"], id: \.self) { BackendLabel(backend: $0) }
            BackendDotStack(backends: ["claude", "codex", "vibe"])
        }
        .padding()
        .background(Color.windowBG)
    }
}
#endif
