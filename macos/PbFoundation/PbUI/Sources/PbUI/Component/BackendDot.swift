import SwiftUI

// MARK: - BackendDot

/// A small coloured dot identifying a backend. Decorative: pair it with a name (`BackendLabel`) or
/// give the container an accessibility label (`BackendDotStack`).
public struct BackendDot: View {
    public let backend: String
    public var size: CGFloat = 8

    public init(backend: String, size: CGFloat = 8) {
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
        HStack(spacing: 5) {
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
    public var size: CGFloat = 10

    public init(backends: [String], size: CGFloat = 10) {
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
        HStack(spacing: -size * 0.3) {
            ForEach(Array(backends.enumerated()), id: \.offset) { _, backend in
                BackendDot(backend: backend, size: size)
                    .overlay(Circle().stroke(Color.windowBG, lineWidth: 1.5))
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(BackendStyle.known + ["mystery"], id: \.self) { BackendLabel(backend: $0) }
            BackendDotStack(backends: ["claude", "codex", "vibe"])
        }
        .padding()
        .background(Color.windowBG)
    }
}
#endif
