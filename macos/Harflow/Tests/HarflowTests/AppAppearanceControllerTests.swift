import AppKit
import Foundation
@testable import Harflow
import HfRepository
import HfTestUtilities
import Testing

@MainActor
@Suite struct AppAppearanceControllerTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "Harflow.Appearance.\(UUID().uuidString)")! }

    @Test func givenPersistedDarkAppearance_whenControllerStarts_thenItAppliesDarkBeforeUpdates() {
        // given
        let settings = SettingsRepositoryImpl(defaults: defaults())
        settings.setAppAppearance(.dark)
        var applied: [String] = []

        // when
        _ = AppAppearanceController(settingsRepository: settings) { appearance in
            applied.append(appearance?.name.rawValue ?? "system")
        }

        // then
        #expect(applied == [NSAppearance.Name.darkAqua.rawValue])
    }

    @Test func givenControllerIsAlive_whenSettingChanges_thenLightDarkAndSystemApplyInOrder() async {
        // given
        let settings = SettingsRepositoryImpl(defaults: defaults())
        var applied: [String] = []
        let controller = AppAppearanceController(settingsRepository: settings) { appearance in
            applied.append(appearance?.name.rawValue ?? "system")
        }

        // when
        settings.setAppAppearance(.light)
        settings.setAppAppearance(.dark)
        settings.setAppAppearance(.system)
        await waitUntil { applied.count == 4 }

        // then
        #expect(applied == ["system", NSAppearance.Name.aqua.rawValue, NSAppearance.Name.darkAqua.rawValue, "system"])
        withExtendedLifetime(controller) {}
    }

    @Test func givenRepeatedAppearanceValue_whenSet_thenControllerDoesNotReapplyIt() async {
        // given
        let settings = SettingsRepositoryImpl(defaults: defaults())
        var applied = 0
        let controller = AppAppearanceController(settingsRepository: settings) { _ in applied += 1 }

        // when
        settings.setAppAppearance(.system)
        settings.setAppAppearance(.system)
        await waitUntil { applied == 1 }

        // then
        #expect(applied == 1)
        withExtendedLifetime(controller) {}
    }

    @Test func givenTwoWindowsAndASheet_whenAppearanceChanges_thenAllCurrentAndFutureWindowsFollow() async {
        // given
        _ = NSApplication.shared
        let settings = SettingsRepositoryImpl(defaults: defaults())
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        windowA.beginSheet(sheet, completionHandler: nil)
        defer {
            windowA.endSheet(sheet)
            windowA.close()
            windowB.close()
            sheet.close()
        }
        let controller = AppAppearanceController(settingsRepository: settings) { NSApp.appearance = $0 }

        // when
        settings.setAppAppearance(.dark)
        let future = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        future.isReleasedWhenClosed = false
        defer { future.close() }

        // then
        await waitUntil {
            NSApp.appearance?.name == NSAppearance.Name.darkAqua
                && windowA.effectiveAppearance.name == NSAppearance.Name.darkAqua
                && windowB.effectiveAppearance.name == NSAppearance.Name.darkAqua
                && sheet.effectiveAppearance.name == NSAppearance.Name.darkAqua
                && future.effectiveAppearance.name == NSAppearance.Name.darkAqua
        }
        #expect(NSApp.appearance?.name == NSAppearance.Name.darkAqua)
        #expect(windowA.effectiveAppearance.name == NSAppearance.Name.darkAqua)
        #expect(windowB.effectiveAppearance.name == NSAppearance.Name.darkAqua)
        #expect(sheet.effectiveAppearance.name == NSAppearance.Name.darkAqua)
        #expect(future.effectiveAppearance.name == NSAppearance.Name.darkAqua)

        // when — System clears the explicit override and leaves OS resolution in charge.
        settings.setAppAppearance(.system)
        await waitUntil { NSApp.appearance == nil }

        // then
        #expect(NSApp.appearance == nil)
        withExtendedLifetime(controller) {}
    }
}
