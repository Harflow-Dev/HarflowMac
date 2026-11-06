import AppKit
import HfRepository
import SwiftUI

// MARK: - SidebarNavigationArtwork

/// Artwork copied without geometry changes from the approved v2 design.
enum SidebarNavigationArtwork: String, CaseIterable {
    case sidebar, plus, hand, workflow, gauge, chart, settings, sun, moon, monitor

    @MainActor private static let images: [Self: NSImage] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { artwork in artwork.load().map { (artwork, $0) } }
    )

    @MainActor var image: NSImage? { Self.images[self] }

    static func appearance(_ appearance: AppAppearance) -> Self {
        switch appearance {
        case .light: .sun
        case .dark: .moon
        case .system: .monitor
        }
    }

    /// App builds resolve only their packaged resource bundle, never a build-machine path.
    static func resourceBundleURL(bundleURL: URL, resourceURL: URL?, moduleBundleURL: @autoclosure () -> URL) -> URL? {
        if bundleURL.pathExtension == "app" {
            resourceURL?.appendingPathComponent("MainWindowFeature_MainWindowFeature.bundle")
        } else {
            moduleBundleURL()
        }
    }

    @MainActor
    func load(bundleURL: URL = Bundle.main.bundleURL, resourceURL: URL? = Bundle.main.resourceURL) -> NSImage? {
        guard let url = Self.resourceBundleURL(bundleURL: bundleURL, resourceURL: resourceURL, moduleBundleURL: Bundle.module.bundleURL),
              let bundle = Bundle(url: url),
              let imageURL = bundle.url(forResource: rawValue, withExtension: "pdf", subdirectory: "NavigationIcons"),
              let image = NSImage(contentsOf: imageURL) else { return nil }
        image.isTemplate = true
        return image
    }
}

// MARK: - SidebarNavigationIcon

/// Decorative template artwork; the containing control supplies its accessible name.
struct SidebarNavigationIcon: View {
    let artwork: SidebarNavigationArtwork
    let size: CGFloat

    init(_ artwork: SidebarNavigationArtwork, size: CGFloat) {
        self.artwork = artwork
        self.size = size
    }

    var body: some View {
        Group {
            if let image = artwork.image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Sidebar navigation artwork") {
    HStack {
        ForEach(SidebarNavigationArtwork.allCases, id: \.self) { SidebarNavigationIcon($0, size: 18) }
    }
    .padding()
}
#endif
