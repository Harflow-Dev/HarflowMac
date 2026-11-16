import HfUI
import SwiftUI

// MARK: - TranscriptComposerHint

/// The transcript composer's printed hint, shared with the skeleton so the two reserve the same row.
struct TranscriptComposerHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TaskScreenStyle.sans(size: MessageBoxStyle.hintSize))
            .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
            .padding(.leading, TaskScreenStyle.Composer.paddingLeading)
    }
}

// MARK: - TranscriptComposerSurface

/// `.hd-composer`'s surface: `surface` fill, 1 pt `border`, and the two `--shadow-composer` layers in black ink.
/// Shared with the loading skeleton's composer placeholder so the two cannot drift.
struct TranscriptComposerSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let composer = TaskScreenStyle.Composer.self
        let shape = RoundedRectangle(cornerRadius: composer.cornerRadius)
        ZStack {
            ForEach(Array(composer.shadow.enumerated()), id: \.offset) { _, layer in
                shape.fill(composer.fill.color)
                    .shadow(
                        color: Color.shadow.opacity(colorScheme == .dark ? layer.darkOpacity : layer.lightOpacity),
                        // CSS blur is the full blur diameter; SwiftUI's radius is half of it.
                        radius: layer.blur / 2,
                        y: layer.offsetY
                    )
            }
            shape.strokeBorder(composer.borderColor.color, lineWidth: composer.borderWidth)
        }
    }
}
