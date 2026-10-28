@testable import HfUI
import Testing

struct HarnessQualificationModelTests {
    @Test func givenUnavailableOrUnsupported_whenPresenting_thenNoCheckAction() {
        // given / when / then
        #expect(HarnessQualificationModel.State.unavailable.actionTitle == nil)
        #expect(HarnessQualificationModel.State.unsupported.actionTitle == nil)
    }

    @Test func givenCancelledOrFailed_whenPresenting_thenRetryIsExplicit() {
        // given / when / then
        for state in [HarnessQualificationModel.State.cancelled, .failed, .failedAtRuntime] {
            #expect(state.actionTitle == "Retry qualification")
        }
        #expect(HarnessQualificationModel.State.checking.actionTitle == "Cancel check")
    }

    @Test func givenLongEngineReason_whenPreparing_thenBoundedAndIncludedInEquality() {
        // given
        let longReason = String(repeating: "x", count: 1200)
        let model = HarnessQualificationModel(identity: "fixture", state: .failed, message: "Failed",
                                              features: [], reason: longReason)
        // when / then
        #expect(model.reason.count == 1000)
        #expect(model != HarnessQualificationModel(identity: "fixture", state: .failed, message: "Failed",
                                                   features: [], reason: "different"))
        #expect(HarnessQualificationModel.Feature(id: "fixture", result: "failed", reason: longReason).reason.count == 1000)
    }

    @Test func givenMultiHarnessActionLabel_whenStateIsUnavailable_thenOverrideCannotEnableAnAction() {
        // given / when / then
        for state in [HarnessQualificationModel.State.unavailable, .unsupported] {
            let model = HarnessQualificationModel(identity: "Fixture", state: state, message: "Fixture", features: [],
                                                   actionTitleOverride: "Check required harnesses")
            #expect(model.actionTitle == nil)
        }
        let ready = HarnessQualificationModel(identity: "Fixture", state: .ready, message: "Fixture", features: [],
                                               actionTitleOverride: "Check required harnesses again")
        #expect(ready.actionTitle == "Check required harnesses again")
    }

}
