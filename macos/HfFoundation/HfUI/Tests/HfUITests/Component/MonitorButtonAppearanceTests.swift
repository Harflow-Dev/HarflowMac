import AppKit
import HfTestUtilities
@testable import HfUI
import SwiftUI
import Testing

// MARK: - MonitorButtonAppearanceTests

@MainActor @Suite(.serialized) struct MonitorButtonAppearanceTests {
    @Observable @MainActor final class Appearance {
        var scheme = ColorScheme.dark
    }

    private struct Fixture: View {
        let appearance: Appearance
        var body: some View {
            Button("New session") {}
                .buttonStyle(MonitorButtonStyle(.glass))
                .frame(width: 240, height: 100)
                .background(Color.windowBG)
                .environment(\.colorScheme, appearance.scheme)
        }
    }

    @Test func givenMountedGlassButton_whenAppearanceCyclesDarkLightDark_thenDarkPixelsReturn() async throws {
        // given — retain the same hosting view and button while changing its environment.
        _ = NSApplication.shared
        let appearance = Appearance()
        let host = NSHostingView(rootView: Fixture(appearance: appearance))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        func pixels() -> [UInt8]? {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Sample the material around the label, away from the changing text antialiasing.
            return (0 ... 10).compactMap { offset in
                let x = Int(CGFloat(bitmap.pixelsWide) * (0.28 + CGFloat(offset) * 0.003))
                let y = bitmap.pixelsHigh / 2
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
                return UInt8(max(0, min(255, color.redComponent * 255)))
            }
        }
        func settle(_ scheme: ColorScheme) async throws -> [UInt8] {
            appearance.scheme = scheme
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            var previous: [UInt8]?
            var stable = 0
            await waitUntil {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                let current = pixels()
                stable = current == previous ? stable + 1 : 0
                previous = current
                return stable >= 8
            }
            return try #require(previous)
        }

        // when
        let firstDark = try await settle(.dark)
        let light = try await settle(.light)
        let finalDark = try await settle(.dark)

        // then — real hosted material pixels must change and recover their original appearance.
        #expect(firstDark.count == 11)
        #expect(zip(firstDark, light).contains { abs(Int($0) - Int($1)) > 20 })
        #expect(zip(firstDark, finalDark).allSatisfy { abs(Int($0) - Int($1)) < 16 })
    }
}
