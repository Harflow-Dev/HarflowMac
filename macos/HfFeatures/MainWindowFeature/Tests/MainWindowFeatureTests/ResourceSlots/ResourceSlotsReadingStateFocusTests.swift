import AppKit
import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - ResourceSlotsReadingStateTests focus authorization

@MainActor
extension ResourceSlotsReadingStateTests {
    @Test func givenFocusedRowAndDepartingResponder_whenAuthorizing_thenItResignsAndAuthorizesTheWindow() {
        // given
        let stub = KeyFocusStub(current: NSResponder())
        let state = focusState(stub)
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn()
        // then
        #expect(stub.resignCalls == 1)
        #expect(state.focusReturnAuthorizedResponder === stub.window)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .resigned && authorized?.focusAuthorizedKind == .window)
    }

    @Test func givenNoFocusedRow_whenAuthorizing_thenNothingIsResignedOrAuthorized() {
        // given
        let stub = KeyFocusStub(current: NSResponder())
        let state = focusState(stub)
        state.focusedRowID = nil
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn()
        // then
        #expect(stub.resignCalls == 0 && !state.hasAuthorizedFocusReturn && state.focusReturnAuthorizedResponder == nil)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .notNeeded && authorized?.focusAuthorizedKind == .absent)
    }

    @Test func givenResponderRefusesToResign_whenAuthorizing_thenTheCurrentResponderIsAuthorized() {
        // given
        let departing = NSResponder()
        let stub = KeyFocusStub(current: departing)
        stub.resignSucceeds = false
        let state = focusState(stub)
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn()
        // then
        #expect(stub.resignCalls == 1)
        #expect(state.focusReturnAuthorizedResponder === departing)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .refused && authorized?.focusAuthorizedKind == .other)
    }

    @Test func givenAnExplicitResponder_whenAuthorizing_thenItIsAuthorizedWithoutResigning() {
        // given
        let stub = KeyFocusStub(current: NSResponder())
        let explicit = NSResponder()
        let state = focusState(stub)
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn(responder: explicit)
        // then
        #expect(stub.resignCalls == 0)
        #expect(state.focusReturnAuthorizedResponder === explicit)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .notNeeded && authorized?.focusAuthorizedKind == .other)
    }

    @Test func givenAWindowWithNoCurrentResponder_whenAuthorizing_thenItResignsAndAuthorizesTheWindow() {
        // given
        let stub = KeyFocusStub(current: nil)
        let state = focusState(stub)
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn()
        // then
        #expect(stub.resignCalls == 1)
        #expect(state.focusReturnAuthorizedResponder === stub.window)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .resigned && authorized?.focusAuthorizedKind == .window)
    }

    @Test func givenNoHostingWindow_whenAuthorizing_thenNothingIsResignedAndNoResponderIsCaptured() {
        // given
        let stub = KeyFocusStub(current: nil)
        stub.hasWindow = false
        let state = focusState(stub)
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn()
        // then
        #expect(stub.resignCalls == 0 && state.hasAuthorizedFocusReturn)
        #expect(state.focusReturnAuthorizedResponder == nil)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .noWindow && authorized?.focusAuthorizedKind == .absent)
    }

    @Test func givenTheWindowAlreadyHoldsFocus_whenAuthorizing_thenNoResignIsCalled() {
        // given
        let stub = KeyFocusStub(current: nil)
        stub.current = stub.window
        let state = focusState(stub)
        var records: [ResourceSlotsDiagnosticRecord] = []
        state.diagnosticObserver = { records.append($0) }
        // when
        state.authorizeFocusReturn()
        // then
        #expect(stub.resignCalls == 0)
        #expect(state.focusReturnAuthorizedResponder === stub.window)
        let authorized = records.last { $0.event == "focus-authorized" }
        #expect(authorized?.focusResign == .notNeeded && authorized?.focusAuthorizedKind == .window)
    }

    /// A window-free host. It holds strong references: the reading state keeps its responder weakly.
    @MainActor fileprivate final class KeyFocusStub {
        let window = NSResponder()
        var current: NSResponder?
        var hasWindow = true
        var resignSucceeds = true
        var resignCalls = 0

        init(current: NSResponder?) { self.current = current }

        var host: ResourceSlotsKeyFocusHost {
            .init(hasWindow: { self.hasWindow }, currentResponder: { self.current }, windowResponder: { self.hasWindow ? self.window : nil },
                  resign: {
                      self.resignCalls += 1
                      if self.resignSucceeds { self.current = self.window }
                      return self.resignSucceeds
                  })
        }
    }

    private func focusState(_ stub: KeyFocusStub) -> ResourceSlotsReadingState {
        let state = ResourceSlotsReadingState()
        state.keyFocusHost = stub.host
        state.focusedRowID = "shared"
        return state
    }
}
