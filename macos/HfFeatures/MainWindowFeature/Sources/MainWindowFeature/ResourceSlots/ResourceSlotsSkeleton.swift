import HfUI
import SwiftUI

struct ResourceSlotsSkeleton: View {
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            bar(width: 110, height: 10).padding(.vertical, 5)
            card(expanded: true)
            card(expanded: false)
            card(expanded: false)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func card(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                bar(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 150, height: 12)
                    bar(width: 200, height: 10)
                }
                Spacer()
            }
            .frame(height: 69)
            if expanded {
                Divider()
                ForEach(0 ..< 3) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        if index != 2 { bar(width: 100, height: 10).padding(.top, 12) }
                        HStack(spacing: 12) {
                            bar(width: 17, height: 17)
                            VStack(alignment: .leading, spacing: 6) {
                                bar(width: 190, height: 12)
                                bar(width: 300, height: 10)
                                if index > 0 { bar(width: 125, height: 10) }
                            }
                            Spacer()
                        }
                        .frame(minHeight: index == 0 ? 64 : 85)
                        Divider()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, expanded ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
    }

    @ViewBuilder private func bar(width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5).fill(Color.neutralFill).frame(width: width, height: height)
        if reduceMotion {
            shape
        } else {
            shape.shimmering().environment(\.shimmerReduceMotionOverride, false)
        }
    }
}
