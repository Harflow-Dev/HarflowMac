import Foundation
@testable import PbRepository
import Testing

@Suite struct SettingsRepositoryImplTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "PbRepositoryTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func givenNoStoredValue_whenRead_thenTheDefaultIsToolDirectoryEmptyAndTogglesTrue() {
        // given
        let defaults = freshDefaults()

        // when
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // then — F8: a key that was never written must read its registered default, not
        // `UserDefaults.bool(forKey:)`'s own `false` for a missing key.
        #expect(sut.toolDirectory == "")
        #expect(sut.openWindowOnStart == true)
        #expect(sut.notifyOnFinish == true)
    }

    @Test func givenAKeyNeverWrittenBefore_whenReadAsABool_thenTheRegisteredDefaultIsUsedNotFalse() {
        // given — F8's regression: `UserDefaults.bool(forKey:)` returns `false` for a key nobody
        // ever wrote, which would silently flip both toggles off for a user who never touched them.
        // A precondition asserting the suite's raw pre-state (e.g. `object(forKey:) == nil`) is not
        // reliable here: this Foundation's volatile registration domain is not cleanly isolated per
        // suite within one process, so an earlier test's `register(defaults:)` call can already be
        // visible on a brand-new suite. What matters, and what is asserted below, is what
        // `SettingsRepositoryImpl` itself reads back — never the naive `false`.
        let defaults = freshDefaults()

        // when
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // then
        #expect(sut.notifyOnFinish == true)
    }

    @Test func givenAWrite_whenRead_thenItIsImmediateAndPersistedToUserDefaults() {
        // given
        let defaults = freshDefaults()
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // when
        sut.setToolDirectory("/opt/homebrew/bin")

        // then
        #expect(sut.toolDirectory == "/opt/homebrew/bin")
        #expect(defaults.string(forKey: SettingsRepositoryImpl.toolDirectoryKey) == "/opt/homebrew/bin")
    }

    @Test func givenASettingWrite_whenObservedFromTwoReaders_thenBothSeeItLive() async {
        // given
        let defaults = freshDefaults()
        let sut = SettingsRepositoryImpl(defaults: defaults)
        var seenByReaderA: [Bool] = []
        var seenByReaderB: [Bool] = []
        let cancellableA = sut.notifyOnFinishPublisher().sink { seenByReaderA.append($0) }
        let cancellableB = sut.notifyOnFinishPublisher().sink { seenByReaderB.append($0) }

        // when
        sut.setNotifyOnFinish(false)

        // then — both subscribers, sharing the one repository instance, observe the same live value.
        #expect(seenByReaderA == [true, false])
        #expect(seenByReaderB == [true, false])
        withExtendedLifetime((cancellableA, cancellableB)) {}
    }

    @Test func givenToolDirectoryAlreadyStored_whenConstructed_thenItReadsTheStoredValueNotTheDefault() {
        // given
        let defaults = freshDefaults()
        defaults.set("/usr/local/bin", forKey: SettingsRepositoryImpl.toolDirectoryKey)

        // when
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // then
        #expect(sut.toolDirectory == "/usr/local/bin")
    }

    @Test func givenSettingsSubscribers_whenIdenticalValuesRepeat_thenInitialAndChangedValuesRemain() {
        // given
        let defaults = freshDefaults()
        let sut = SettingsRepositoryImpl(defaults: defaults)
        var directories: [String] = []
        var openings: [Bool] = []
        var notifications: [Bool] = []
        let subscriptions = [
            sut.toolDirectoryPublisher().sink { directories.append($0) },
            sut.openWindowOnStartPublisher().sink { openings.append($0) },
            sut.notifyOnFinishPublisher().sink { notifications.append($0) }
        ]
        // when
        for value in ["", "/fixture/tools", "/fixture/tools", ""] { sut.setToolDirectory(value) }
        for value in [true, false, false, true] {
            sut.setOpenWindowOnStart(value)
            sut.setNotifyOnFinish(value)
        }
        // then
        #expect(directories == ["", "/fixture/tools", ""])
        #expect(openings == [true, false, true])
        #expect(notifications == [true, false, true])
        #expect(defaults.string(forKey: SettingsRepositoryImpl.toolDirectoryKey) == "")
        withExtendedLifetime(subscriptions) {}
    }

}
