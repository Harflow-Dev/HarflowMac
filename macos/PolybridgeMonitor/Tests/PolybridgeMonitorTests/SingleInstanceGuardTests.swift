//
//  SingleInstanceGuardTests.swift
//  PolybridgeMonitorTests
//
//  Pure tests over `SingleInstanceGuard.findDuplicate` — no real running app, no AppKit.
//

import Foundation
@testable import PolybridgeMonitor
import Testing

@Suite struct SingleInstanceGuardTests {

    private static let selfIdentifier = "dev.polybridge.monitor"
    private static let selfURL = URL(fileURLWithPath: "/Applications/Polybridge Monitor.app")
    private static let selfPID: pid_t = 100

    private func findDuplicate(among runningApps: [RunningAppSnapshot]) -> RunningAppSnapshot? {
        SingleInstanceGuard.findDuplicate(
            among: runningApps,
            selfBundleIdentifier: Self.selfIdentifier,
            selfBundleURL: Self.selfURL,
            selfProcessIdentifier: Self.selfPID
        )
    }

    @Test func givenConcurrentCopies_whenBothCheckForDuplicates_thenExactlyOneRemainsPrimary() {
        // given
        let first = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: Self.selfURL,
            isTerminated: false, processIdentifier: 100
        )
        let second = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/tmp/Polybridge Monitor.app"),
            isTerminated: false, processIdentifier: 200
        )
        let apps = [second, first]

        // when
        let firstDuplicate = SingleInstanceGuard.findDuplicate(
            among: apps, selfBundleIdentifier: first.bundleIdentifier,
            selfBundleURL: first.bundleURL, selfProcessIdentifier: first.processIdentifier
        )
        let secondDuplicate = SingleInstanceGuard.findDuplicate(
            among: apps, selfBundleIdentifier: second.bundleIdentifier,
            selfBundleURL: second.bundleURL, selfProcessIdentifier: second.processIdentifier
        )

        // then
        #expect(firstDuplicate == nil)
        #expect(secondDuplicate == first)
    }

    @Test func givenOlderPrimaryWithHigherPID_whenANewerCopyLaunches_thenTheOlderCopyWins() {
        // given
        let older = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: Self.selfURL,
            isTerminated: false, processIdentifier: 999, launchDate: Date(timeIntervalSince1970: 0)
        )
        let newer = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: URL(fileURLWithPath: "/tmp/Monitor.app"),
            isTerminated: false, processIdentifier: 100, launchDate: Date(timeIntervalSince1970: 1)
        )

        // when / then — both views of the same concurrent launch agree despite PID reuse.
        for apps in [[older, newer], [newer, older]] {
            #expect(SingleInstanceGuard.findDuplicate(
                among: apps, selfBundleIdentifier: Self.selfIdentifier, selfBundleURL: older.bundleURL,
                selfProcessIdentifier: older.processIdentifier, selfLaunchDate: older.launchDate
            ) == nil)
            #expect(SingleInstanceGuard.findDuplicate(
                among: apps, selfBundleIdentifier: Self.selfIdentifier, selfBundleURL: newer.bundleURL,
                selfProcessIdentifier: newer.processIdentifier, selfLaunchDate: newer.launchDate
            ) == older)
        }
    }

    @Test func givenEqualLaunchDates_whenBothCopiesCheck_thenPIDBreaksTheTie() {
        // given
        let date = Date(timeIntervalSince1970: 1)
        let other = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: URL(fileURLWithPath: "/tmp/Monitor.app"),
            isTerminated: false, processIdentifier: 50, launchDate: date
        )

        // when
        let found = SingleInstanceGuard.findDuplicate(
            among: [other], selfBundleIdentifier: Self.selfIdentifier, selfBundleURL: Self.selfURL,
            selfProcessIdentifier: Self.selfPID, selfLaunchDate: date
        )

        // then
        #expect(found == other)
    }

    @Test func givenAnUnknownLaunchDate_whenSelfHasAKnownDate_thenSelfRemainsPrimary() {
        // given
        let other = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: URL(fileURLWithPath: "/tmp/Monitor.app"),
            isTerminated: false, processIdentifier: 50
        )

        // when
        let found = SingleInstanceGuard.findDuplicate(
            among: [other], selfBundleIdentifier: Self.selfIdentifier, selfBundleURL: Self.selfURL,
            selfProcessIdentifier: Self.selfPID, selfLaunchDate: Date(timeIntervalSince1970: 1)
        )

        // then
        #expect(found == nil)
    }

    @Test func givenSeveralOlderCopies_whenTheirListingOrderChanges_thenTheOldestIsAlwaysChosen() {
        // given
        let oldest = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: URL(fileURLWithPath: "/tmp/Oldest.app"),
            isTerminated: false, processIdentifier: 300, launchDate: Date(timeIntervalSince1970: 0)
        )
        let other = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: URL(fileURLWithPath: "/tmp/Other.app"),
            isTerminated: false, processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 1)
        )

        // when / then
        for apps in [[oldest, other], [other, oldest]] {
            #expect(SingleInstanceGuard.findDuplicate(
                among: apps, selfBundleIdentifier: Self.selfIdentifier, selfBundleURL: Self.selfURL,
                selfProcessIdentifier: Self.selfPID, selfLaunchDate: Date(timeIntervalSince1970: 2)
            ) == oldest)
        }
    }

    @Test func givenNoOtherRunningApps_whenFindingADuplicate_thenNoneIsFound() {
        // given / when
        let duplicate = findDuplicate(among: [])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenAnotherNonTerminatedAppWithTheSameIdentifierAtADifferentURL_whenFindingADuplicate_thenItIsFound() {
        // given
        let other = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app"),
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = findDuplicate(among: [other])

        // then
        #expect(duplicate == other)
    }

    @Test func givenAMatchAtTheExactSameBundleURL_whenFindingADuplicate_thenItIsNotADuplicate() {
        // given — same path, standardized/resolved the same way; macOS never launches a second
        // process from one bundle path, so this is never a duplicate.
        let samePath = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: Self.selfURL,
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = findDuplicate(among: [samePath])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenAMatchAtAnUnstandardizedButEquivalentURL_whenFindingADuplicate_thenItIsNotADuplicate() {
        // given — same path expressed with a redundant path component; normalization must treat
        // these as identical, not as "different".
        let equivalentPath = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/../Applications/Polybridge Monitor.app"),
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = findDuplicate(among: [equivalentPath])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenATerminatedAppAtADifferentURL_whenFindingADuplicate_thenItIsIgnored() {
        // given
        let terminated = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app"),
            isTerminated: true,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = findDuplicate(among: [terminated])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenAnAppWithADifferentBundleIdentifier_whenFindingADuplicate_thenItIsIgnored() {
        // given
        let unrelated = RunningAppSnapshot(
            bundleIdentifier: "com.example.other",
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = findDuplicate(among: [unrelated])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenThisProcesssOwnEntry_whenFindingADuplicate_thenItIsIgnored() {
        // given — same identifier and pid as self, even though `NSWorkspace.runningApplications`
        // would report a different bundle URL for it in a real environment it should never match.
        let ownEntry = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app"),
            isTerminated: false,
            processIdentifier: Self.selfPID
        )

        // when
        let duplicate = findDuplicate(among: [ownEntry])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenSelfBundleIdentifierIsNil_whenFindingADuplicate_thenNoneIsFound() {
        // given
        let other = RunningAppSnapshot(
            bundleIdentifier: "dev.polybridge.monitor",
            bundleURL: URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app"),
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = SingleInstanceGuard.findDuplicate(
            among: [other], selfBundleIdentifier: nil, selfBundleURL: Self.selfURL, selfProcessIdentifier: Self.selfPID
        )

        // then
        #expect(duplicate == nil)
    }

    @Test func givenSelfBundleURLIsNil_whenFindingADuplicate_thenNoneIsFound() {
        // given — nothing to compare a candidate's path against, so no mismatch is asserted.
        let other = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app"),
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = SingleInstanceGuard.findDuplicate(
            among: [other], selfBundleIdentifier: Self.selfIdentifier, selfBundleURL: nil, selfProcessIdentifier: Self.selfPID
        )

        // then
        #expect(duplicate == nil)
    }

    @Test func givenACandidateWithNoBundleURL_whenFindingADuplicate_thenItIsIgnored() {
        // given
        let noURL = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier, bundleURL: nil, isTerminated: false, processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let duplicate = findDuplicate(among: [noURL])

        // then
        #expect(duplicate == nil)
    }

    @Test func givenSeveralRunningApps_whenFindingADuplicate_thenTheFirstMatchingOneIsReturned() {
        // given
        let unrelated = RunningAppSnapshot(
            bundleIdentifier: "com.example.other",
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            isTerminated: false,
            processIdentifier: 150
        )
        let duplicate = RunningAppSnapshot(
            bundleIdentifier: Self.selfIdentifier,
            bundleURL: URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app"),
            isTerminated: false,
            processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 0)
        )

        // when
        let found = findDuplicate(among: [unrelated, duplicate])

        // then
        #expect(found == duplicate)
    }
}
