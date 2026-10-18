import Foundation
@testable import PbUI
import Testing

@Suite struct FormatTests {
    
    // MARK: - clock
    
    @Test func givenNilSeconds_whenFormattingClock_thenReturnsPlaceholder() {
        // given / when / then
        #expect(Format.clock(nil) == "--:--")
    }
    
    @Test func givenNonFiniteSeconds_whenFormattingClock_thenReturnsPlaceholder() {
        // given / when / then
        #expect(Format.clock(.infinity) == "--:--")
        #expect(Format.clock(.nan) == "--:--")
    }
    
    @Test func givenSecondsUnderAnHour_whenFormattingClock_thenReturnsMinutesAndSeconds() {
        // given / when / then
        #expect(Format.clock(65) == "01:05")
        #expect(Format.clock(0) == "00:00")
    }
    
    @Test func givenSecondsOverAnHour_whenFormattingClock_thenIncludesHours() {
        // given / when / then
        #expect(Format.clock(3661) == "1:01:01")
    }
    
    // MARK: - age
    
    @Test func givenNilDate_whenFormattingAge_thenReturnsEmptyString() {
        // given / when / then
        #expect(Format.age(nil) == "")
    }
    
    @Test func givenADateUnderAMinuteAgo_whenFormattingAge_thenReturnsNow() {
        // given
        let now = Date()
        let date = now.addingTimeInterval(-30)
        
        // when / then
        #expect(Format.age(date, now: now) == "now")
    }
    
    @Test func givenADateMinutesAgo_whenFormattingAge_thenReturnsMinutes() {
        // given
        let now = Date()
        let date = now.addingTimeInterval(-125)
        
        // when / then
        #expect(Format.age(date, now: now) == "2m")
    }
    
    @Test func givenADateHoursAgo_whenFormattingAge_thenReturnsHours() {
        // given
        let now = Date()
        let date = now.addingTimeInterval(-3 * 3600 - 10)
        
        // when / then
        #expect(Format.age(date, now: now) == "3h")
    }
    
    @Test func givenADateDaysAgo_whenFormattingAge_thenReturnsDays() {
        // given
        let now = Date()
        let date = now.addingTimeInterval(-2 * 86400 - 10)
        
        // when / then
        #expect(Format.age(date, now: now) == "2d")
    }
    
    // MARK: - offset
    
    @Test func givenNilStartOrDate_whenFormattingOffset_thenReturnsEmptyString() {
        // given
        let date = Date()
        
        // when / then
        #expect(Format.offset(nil, from: date) == "")
        #expect(Format.offset(date, from: nil) == "")
    }
    
    @Test func givenAStartAndALaterDate_whenFormattingOffset_thenReturnsTheElapsedClock() {
        // given
        let start = Date(timeIntervalSince1970: 0)
        let date = start.addingTimeInterval(90)
        
        // when / then
        #expect(Format.offset(date, from: start) == "01:30")
    }
    
    // MARK: - repo
    
    @Test func givenAPathUnderHome_whenFormattingRepo_thenAbbreviatesWithTilde() {
        // given
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let path = home + "/Code/polybridge"
        
        // when / then
        #expect(Format.repo(path) == "~/Code/polybridge")
    }
    
    @Test func givenAPathOutsideHome_whenFormattingRepo_thenReturnsItUnchanged() {
        // given
        let path = "/opt/somewhere"
        
        // when / then
        #expect(Format.repo(path) == path)
    }

    // MARK: - repoName

    @Test func givenAnAbsolutePath_whenFormattingRepoName_thenReturnsTheLastComponent() {
        // given / when / then
        #expect(Format.repoName("/Users/me/Code/polybridge") == "polybridge")
    }

    @Test func givenATrailingSlash_whenFormattingRepoName_thenIgnoresIt() {
        // given / when / then
        #expect(Format.repoName("/Users/me/Code/polybridge/") == "polybridge")
    }

    @Test func givenABareNameOrEmptyPath_whenFormattingRepoName_thenReturnsItAsIs() {
        // given / when / then
        #expect(Format.repoName("polybridge") == "polybridge")
        #expect(Format.repoName("") == "")
    }
}
