import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - SidebarNavigationIconTests

@Suite @MainActor
struct SidebarNavigationIconTests {
    @Test(arguments: SidebarNavigationArtwork.allCases)
    func givenBundledArtwork_whenLoading_thenTemplateImageContainsVisibleSquareArtwork(_ artwork: SidebarNavigationArtwork) throws {
        // given / when
        let image = try #require(artwork.load())
        // then
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
        #expect(image.size.width == image.size.height)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 48, height: 48))
        image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        #expect((0 ..< 48).contains { x in
            (0 ..< 48).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
        })
        #expect((0 ..< 48).contains { x in
            (0 ..< 48).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) == 0 }
        })
    }

    @Test func givenPackagedApplication_whenResolvingResources_thenOnlyPackagedBundleIsSelected() {
        // given
        let app = URL(fileURLWithPath: "/fixture/Harflow.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        var evaluatedModuleBundle = false
        func moduleBundleURL() -> URL {
            evaluatedModuleBundle = true
            return URL(fileURLWithPath: "/unavailable/build/Module.bundle")
        }
        // when / then
        #expect(SidebarNavigationArtwork.resourceBundleURL(bundleURL: app, resourceURL: resources, moduleBundleURL: moduleBundleURL())
            == resources.appendingPathComponent("MainWindowFeature_MainWindowFeature.bundle"))
        #expect(SidebarNavigationArtwork.resourceBundleURL(bundleURL: app, resourceURL: nil, moduleBundleURL: moduleBundleURL()) == nil)
        #expect(!evaluatedModuleBundle)
    }

    @Test func givenStandalonePackage_whenResolvingResources_thenModuleBundleIsSelected() {
        // given
        let module = URL(fileURLWithPath: "/fixture/Module.bundle")
        // when
        let result = SidebarNavigationArtwork.resourceBundleURL(
            bundleURL: URL(fileURLWithPath: "/fixture/tests.xctest"), resourceURL: nil, moduleBundleURL: module
        )
        // then
        #expect(result == module)
    }
}
