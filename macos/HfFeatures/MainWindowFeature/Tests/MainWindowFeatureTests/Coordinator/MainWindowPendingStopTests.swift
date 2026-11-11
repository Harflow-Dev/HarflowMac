import AppKit
import Foundation
import HfCommon
import HfCommonTestMock
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor
private final class Recorder {
    var confirms = 0
    var cancels: [PendingLaunchStopCancelReason] = []
    var dismissals: [UUID] = []
    /// The sheet at the time of each dismissal callback: it must already be gone.
    var sheetAtDismissal: [MainWindowSheet?] = []
    weak var coordinator: MainWindowCoordinator?

    func request() -> PendingLaunchStopRequest {
        PendingLaunchStopRequest(
            id: UUID(), taskID: "20261110-093000-a17c92",
            confirm: { self.confirms += 1 },
            cancel: { self.cancels.append($0) },
            didDismiss: {
                self.dismissals.append($0)
                self.sheetAtDismissal.append(self.coordinator?.presentedSheet)
            }
        )
    }
}

@MainActor
@Suite struct MainWindowPendingStopTests {
    private func coordinator(_ recorder: Recorder) -> MainWindowCoordinator {
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .pendingLaunches
        recorder.coordinator = sut
        return sut
    }

    @Test func givenReadyPendingLaunches_whenPresented_thenSheetShown() {
        // given
        let recorder = Recorder()
        let sut = coordinator(recorder)
        // when
        sut.presentPendingLaunchStop(recorder.request())
        // then
        #expect(sut.presentedSheet == .stopPendingLaunch)
        #expect(sut.pendingStopRequest != nil)
        #expect(recorder.cancels.isEmpty)
    }

    @Test func givenRejectedPresentations_whenRequested_thenDiscardedOnceEach() {
        // given: another sheet, another destination
        let other = Recorder()
        let sut = coordinator(other)
        sut.presentedSheet = .workflowRunner
        // when
        sut.presentPendingLaunchStop(other.request())
        // then
        #expect(other.cancels == [.discard])
        #expect(sut.presentedSheet == .workflowRunner)
        // given
        let elsewhere = Recorder()
        let second = coordinator(elsewhere)
        second.selection = .statistics
        // when
        second.presentPendingLaunchStop(elsewhere.request())
        // then
        #expect(elsewhere.cancels == [.discard])
        #expect(second.presentedSheet == nil)
    }

    @Test func givenSheet_whenConfirmed_thenConfirmOnceAndNoCancel() {
        // given
        let recorder = Recorder()
        let sut = coordinator(recorder)
        let request = recorder.request()
        sut.presentPendingLaunchStop(request)
        // when
        sut.confirmPendingStop(requestID: UUID())
        sut.confirmPendingStop(requestID: request.id)
        sut.confirmPendingStop(requestID: request.id)
        // then
        #expect(recorder.confirms == 1)
        #expect(recorder.cancels.isEmpty)
        #expect(sut.presentedSheet == nil)
        // The view model hears about it only from the native dismissal, scoped to this request.
        #expect(recorder.dismissals.isEmpty)
        sut.pendingLaunchStopSheetDidDismiss()
        sut.pendingLaunchStopSheetDidDismiss()
        #expect(recorder.dismissals == [request.id])
        #expect(recorder.sheetAtDismissal == [nil])
    }

    @Test func givenSheet_whenCancelPressed_thenUserCancelOnceThenDismissedAfterSheetIsGone() {
        // given
        let recorder = Recorder()
        let sut = coordinator(recorder)
        let request = recorder.request()
        sut.presentPendingLaunchStop(request)
        // when
        sut.cancelPendingStop(requestID: request.id)
        sut.cancelPendingStop(requestID: request.id)
        // then
        #expect(recorder.cancels == [.userCancel])
        #expect(recorder.confirms == 0)
        #expect(recorder.dismissals.isEmpty)
        sut.pendingLaunchStopSheetDidDismiss()
        #expect(recorder.dismissals == [request.id])
        #expect(recorder.sheetAtDismissal == [nil])
    }

    private enum Route: CaseIterable { case bindingNil, replaced, leftDestination, dismissRouting }

    @Test func givenSheet_whenItEndsAnyOtherWay_thenDiscardedExactlyOnce() {
        for route in Route.allCases {
            // given
            let recorder = Recorder()
            let sut = coordinator(recorder)
            let request = recorder.request()
            sut.presentPendingLaunchStop(request)
            // when
            switch route {
            case .bindingNil: sut.presentedSheet = nil
            case .replaced: sut.presentedSheet = .workflowRunner
            case .leftDestination: sut.selection = .statistics
            case .dismissRouting: sut.dismissPendingLaunchStop()
            }
            sut.dismissPendingLaunchStop()
            sut.pendingLaunchStopSheetDidDismiss()
            sut.pendingLaunchStopSheetDidDismiss()
            // then
            #expect(recorder.dismissals == [request.id], "\(route)")
            #expect(recorder.cancels == [.discard], "\(route)")
            #expect(recorder.confirms == 0, "\(route)")
            #expect(sut.pendingStopRequest == nil, "\(route)")
            if route != .replaced { #expect(sut.presentedSheet == nil, "\(route)") }
        }
    }

    @Test func givenNoRequest_whenSheetBuilt_thenNothingIsRenderedAndAPresentedRequestRendersTheSheet() {
        // given
        let recorder = Recorder()
        let sut = coordinator(recorder)
        func fittingSize(_ view: AnyView) -> CGSize { NSHostingView(rootView: view).fittingSize }
        // when / then: no request renders no controls, and a stray sheet value is refused.
        #expect(fittingSize(sut.buildPendingLaunchStopView()).height < 20)
        sut.presentedSheet = .stopPendingLaunch
        #expect(sut.presentedSheet == nil)
        // when
        sut.presentPendingLaunchStop(recorder.request())
        // then
        #expect(fittingSize(sut.buildPendingLaunchStopView()).height > 100)
    }

    @Test func givenRequestFromAnEarlierSheet_whenANewOneIsPresented_thenAStaleDismissalIsNotMistakenForIt() {
        // given
        let recorder = Recorder()
        let sut = coordinator(recorder)
        let first = recorder.request()
        sut.presentPendingLaunchStop(first)
        sut.cancelPendingStop(requestID: first.id)
        // when: the first dismissal callback never arrives before the next request is shown
        let second = recorder.request()
        sut.presentPendingLaunchStop(second)
        sut.pendingLaunchStopSheetDidDismiss()
        // then
        #expect(recorder.dismissals.isEmpty)
        #expect(sut.pendingStopRequest?.id == second.id)
    }
}
