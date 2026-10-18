import Foundation
import MonitorCore
@testable import SettingsFeature
import Testing

@Suite struct HarnessRowActionsTests {
    
    private func row(_ json: String) throws -> HarnessRow {
        try SetupDocument.decode(stdout: Data(#"{"v":1,"clients":[\#(json)]}"#.utf8), stderr: "", exitCode: 0).get().rows[0]
    }
    
    @Test func givenARowNotAvailable_whenRenderingActions_thenInstallIsDisabled() throws {
        // given
        let notAvailable = try row(#"{"key":"codex","available":false}"#)
        
        // then
        #expect(HarnessRowActions.isInstallDisabled(row: notAvailable, isAnyWorking: false) == true)
    }
    
    @Test func givenARowAvailable_whenNothingIsWorking_thenInstallIsEnabled() throws {
        // given
        let available = try row(#"{"key":"codex","available":true}"#)
        
        // then
        #expect(HarnessRowActions.isInstallDisabled(row: available, isAnyWorking: false) == false)
    }
    
    @Test func givenAnyRowWorking_whenRenderingActions_thenInstallIsDisabledEvenIfAvailable() throws {
        // given
        let available = try row(#"{"key":"codex","available":true}"#)
        
        // then
        #expect(HarnessRowActions.isInstallDisabled(row: available, isAnyWorking: true) == true)
    }
    
    @Test func givenInstalledIsExplicitlyFalse_whenRenderingActions_thenRemoveIsDisabled() throws {
        // given
        let notInstalled = try row(#"{"key":"codex","available":true,"installed":false}"#)
        
        // then
        #expect(HarnessRowActions.isRemoveDisabled(row: notInstalled, isAnyWorking: false) == true)
    }
    
    @Test func givenInstalledIsUnknown_whenRenderingActions_thenRemoveIsEnabled() throws {
        // given — `installed == nil` means "could not tell," a real, testable distinction from
        // `== false` (F4-45).
        let unknown = try row(#"{"key":"codex","available":true}"#)
        
        // then
        #expect(unknown.installed == nil)
        #expect(HarnessRowActions.isRemoveDisabled(row: unknown, isAnyWorking: false) == false)
    }
    
    @Test func givenInstalledIsTrue_whenRenderingActions_thenRemoveIsEnabled() throws {
        // given
        let installed = try row(#"{"key":"codex","available":true,"installed":true}"#)
        
        // then
        #expect(HarnessRowActions.isRemoveDisabled(row: installed, isAnyWorking: false) == false)
    }

    @Test func givenAnInstalledRowThatIsNotCurrent_whenRenderingActions_thenItReadsAsAnUpdate() throws {
        // given — registered, but not what install would write now (e.g. a stale PATH)
        let stale = try row(#"{"key":"codex","available":true,"installed":true,"current":false}"#)

        // then
        #expect(HarnessRowActions.isOutOfDate(row: stale))
        #expect(HarnessRowActions.installTitle(row: stale) == "Update")
    }

    @Test func givenRowsThatAreNotOutOfDate_whenRenderingActions_thenTheyKeepInstallOrReinstall() throws {
        // given — current, could-not-tell, and not installed (even with current false)
        let current = try row(#"{"key":"codex","available":true,"installed":true,"current":true}"#)
        let unknownCurrency = try row(#"{"key":"codex","available":true,"installed":true}"#)
        let notInstalled = try row(#"{"key":"codex","available":true,"installed":false,"current":false}"#)

        // then
        #expect(!HarnessRowActions.isOutOfDate(row: current))
        #expect(HarnessRowActions.installTitle(row: current) == "Reinstall")
        #expect(!HarnessRowActions.isOutOfDate(row: unknownCurrency))
        #expect(HarnessRowActions.installTitle(row: unknownCurrency) == "Reinstall")
        #expect(!HarnessRowActions.isOutOfDate(row: notInstalled))
        #expect(HarnessRowActions.installTitle(row: notInstalled) == "Install")
    }
}
