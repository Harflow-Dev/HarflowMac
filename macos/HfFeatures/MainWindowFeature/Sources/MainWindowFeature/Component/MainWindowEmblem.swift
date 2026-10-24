import AppKit
import Foundation

// MARK: - MainWindowEmblem

/// Template menu-bar emblem image loaded from the bundled branding resources.
@MainActor
enum MainWindowEmblem {
    /// Shared emblem, or `nil` when the branding resources are unavailable.
    static let image: NSImage? = load()

    /// Loads the 1x image and attaches the 2x representation from the branding directory under the app bundle
    /// resources, or from the module bundle outside an app bundle. Returns `nil` if either file is unreadable.
    static func load(bundleURL: URL = Bundle.main.bundleURL, resourceURL: URL? = Bundle.main.resourceURL) -> NSImage? {
        let brandingURL: URL? = if bundleURL.pathExtension == "app" {
            resourceURL?.appendingPathComponent("MainWindowFeature_MainWindowFeature.bundle/Branding")
        } else {
            Bundle.module.url(forResource: "Branding", withExtension: nil)
        }
        guard let brandingURL,
              let image = NSImage(contentsOf: brandingURL.appendingPathComponent("menubarTemplate.png")),
              let highResolutionData = try? Data(contentsOf: brandingURL.appendingPathComponent("menubarTemplate@2x.png")),
              let highResolution = NSBitmapImageRep(data: highResolutionData) else {
            return nil
        }
        highResolution.size = image.size
        image.addRepresentation(highResolution)
        image.isTemplate = true
        return image
    }
}
