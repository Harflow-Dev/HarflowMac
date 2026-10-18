@testable import MainWindowFeature
import PbCommon
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SidebarNativeEnvironmentFingerprintTests {
    @Test func givenDefaultEnvironment_whenFingerprintChangesOneInputAtATime_thenEveryInputIsObserved() {
        var environment = EnvironmentValues()
        // given — mutate every supported fingerprint input before reading the immutable value.
        environment.font = .system(size: 13)
        environment.defaultMinListRowHeight = 8
        environment.colorScheme = .dark
        environment.legibilityWeight = .bold
        environment.dynamicTypeSize = .accessibility2
        environment.locale = Locale(identifier: "id-ID")
        environment.layoutDirection = .rightToLeft
        environment.displayScale = 2
        environment.controlSize = .large
        environment.isEnabled = false
        environment.pbReduceMotionOverride = true
        environment.shimmerReduceMotionOverride = false

        // when — construct the production fingerprint.
        let fingerprint = SidebarNativeEnvironmentFingerprint(environment)

        // then — every input survives the projection.
        #expect(fingerprint.minimumHeight == 8)
        #expect(fingerprint.colorScheme == .dark)
        #expect(fingerprint.contrast == EnvironmentValues().colorSchemeContrast)
        #expect(fingerprint.legibility == .bold)
        #expect(fingerprint.dynamicType == .accessibility2)
        #expect(fingerprint.locale.identifier == "id-ID")
        #expect(fingerprint.direction == .rightToLeft)
        #expect(fingerprint.displayScale == 2)
        #expect(fingerprint.controlSize == .large)
        #expect(!fingerprint.enabled)
        #expect(fingerprint.reduceMotion == EnvironmentValues().accessibilityReduceMotion)
        #expect(fingerprint.motionOverride == true)
        #expect(fingerprint.shimmerOverride == false)
    }

    @Test func givenEqualEnvironment_whenFingerprintIsCompared_thenNoRefreshIsRequired() {
        // given / when
        let first = SidebarNativeEnvironmentFingerprint(EnvironmentValues())
        let second = SidebarNativeEnvironmentFingerprint(EnvironmentValues())

        // then
        #expect(first == second)
    }
}
