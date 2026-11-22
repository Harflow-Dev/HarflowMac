import Foundation
@testable import HfRepository
import HfTestUtilities
import Testing

@Suite struct SettingsRepositoryImplTests {

    @Test func givenNoStoredValue_whenRead_thenTheTogglesDefaultToTrue() {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults

        // when
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // then — F8: a key that was never written must read its registered default, not
        // `UserDefaults.bool(forKey:)`'s own `false` for a missing key.
        #expect(sut.openWindowOnStart == true)
        #expect(sut.notifyOnFinish == true)
        #expect(sut.appAppearance == .system)
    }

    @Test func givenAnInvalidAppearanceValue_whenConstructed_thenSystemIsUsedAndOtherSettingsSurvive() {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults
        defaults.set("unsupported", forKey: SettingsRepositoryImpl.appAppearanceKey)
        defaults.set(false, forKey: SettingsRepositoryImpl.notifyOnFinishKey)

        // when
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // then
        #expect(sut.appAppearance == .system)
        #expect(sut.notifyOnFinish == false)
    }

    @Test func givenAppearanceSubscribers_whenValuesRepeat_thenInitialAndChangedValuesRemain() {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let sut = SettingsRepositoryImpl(defaults: scratch.defaults)
        var values: [AppAppearance] = []
        let token = sut.appAppearancePublisher().sink { values.append($0) }

        // when
        sut.setAppAppearance(.dark)
        sut.setAppAppearance(.dark)
        sut.setAppAppearance(.light)

        // then
        #expect(values == [.system, .dark, .light])
        withExtendedLifetime(token) {}
    }

    @Test func givenAppearanceWasPersisted_whenRepositoryRestarts_thenItIsReconstructed() {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults
        SettingsRepositoryImpl(defaults: defaults).setAppAppearance(.dark)

        // when
        let restored = SettingsRepositoryImpl(defaults: defaults)

        // then
        #expect(restored.appAppearance == .dark)
    }

    @Test func givenAKeyNeverWrittenBefore_whenReadAsABool_thenTheRegisteredDefaultIsUsedNotFalse() {
        // given — F8's regression: `UserDefaults.bool(forKey:)` returns `false` for a key nobody
        // ever wrote, which would silently flip both toggles off for a user who never touched them.
        // A precondition asserting the suite's raw pre-state (e.g. `object(forKey:) == nil`) is not
        // reliable here: this Foundation's volatile registration domain is not cleanly isolated per
        // suite within one process, so an earlier test's `register(defaults:)` call can already be
        // visible on a brand-new suite. What matters, and what is asserted below, is what
        // `SettingsRepositoryImpl` itself reads back — never the naive `false`.
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults

        // when
        let sut = SettingsRepositoryImpl(defaults: defaults)

        // then
        #expect(sut.notifyOnFinish == true)
    }

    @Test func givenASettingWrite_whenObservedFromTwoReaders_thenBothSeeItLive() async {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults
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

    @Test func givenSettingsSubscribers_whenIdenticalValuesRepeat_thenInitialAndChangedValuesRemain() {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults
        let sut = SettingsRepositoryImpl(defaults: defaults)
        var openings: [Bool] = []
        var notifications: [Bool] = []
        let subscriptions = [
            sut.openWindowOnStartPublisher().sink { openings.append($0) },
            sut.notifyOnFinishPublisher().sink { notifications.append($0) }
        ]
        // when
        for value in [true, false, false, true] {
            sut.setOpenWindowOnStart(value)
            sut.setNotifyOnFinish(value)
        }
        // then
        #expect(openings == [true, false, true])
        #expect(notifications == [true, false, true])
        withExtendedLifetime(subscriptions) {}
    }

    @Test func givenNoStoredValue_whenReadingNeedsYouNotification_thenDefaultsOnAndPersists() {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults
        let sut = SettingsRepositoryImpl(defaults: defaults)
        // when / then
        #expect(sut.notifyOnNeedsYou)
        sut.setNotifyOnNeedsYou(false)
        #expect(!sut.notifyOnNeedsYou)
        #expect(!SettingsRepositoryImpl(defaults: defaults).notifyOnNeedsYou)
        #expect(defaults.object(forKey: "notifyOnNeedsYou") as? Bool == false)
    }

    @Test func givenSettingsAsTheProtocol_whenNeedsYouIsTurnedOff_thenItIsStoredAndPublished() {
        // given — the repository is held as the protocol, as every production caller holds it, so a
        // setter that is not a protocol requirement would dispatch statically to an extension default.
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = scratch.defaults
        let sut: any SettingsRepository = SettingsRepositoryImpl(defaults: defaults)
        var values: [Bool] = []
        let token = sut.notifyOnNeedsYouPublisher().sink { values.append($0) }

        // when
        sut.setNotifyOnNeedsYou(false)

        // then
        #expect(sut.notifyOnNeedsYou == false)
        #expect(values == [true, false])
        #expect(defaults.object(forKey: SettingsRepositoryImpl.notifyOnNeedsYouKey) as? Bool == false)
        withExtendedLifetime(token) {}
    }
}
