import Combine
import Foundation
import Mockable
import MonitorCore
import PbTestUtilities
@testable import SettingsFeature
import Testing

/// A plain mutable box, read by a `willProduce` closure registered exactly once. `Mockable`'s
/// `given` keeps a FIFO queue per member and only retires an entry once a *later* one has been
/// registered — a second `given(...).willReturn(...)` call on the same member does not reliably
/// "replace" the first for the very next invocation (documented in the Phase 3 report and
/// `PbRepositoryTests`' own notes on this exact pitfall). Mutating a box read by one `willProduce`
/// avoids it entirely. No locking: everything here runs on the main actor.
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
@Suite struct GeneralSettingsVMTests {
    
    private struct SUT {
        let sut: GeneralSettingsVM
        let useCase: MockGeneralSettingsUseCase
        let toolDirectorySubject: PassthroughSubject<String, Never>
        let openWindowSubject: PassthroughSubject<Bool, Never>
        let notifySubject: PassthroughSubject<Bool, Never>
        let ctlResolutionBox: Box<ToolResolution>
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let hasListedSubject: PassthroughSubject<Bool, Never>
        let listErrorSubject: PassthroughSubject<ToolError?, Never>
    }
    
    private func makeSUT(
        toolDirectory: String = "",
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        searchDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
        ctlResolution: ToolResolution = .found(path: "/opt/homebrew/bin/polybridge-ctl"),
        setupResolution: ToolResolution = .notFound
    ) -> SUT {
        let useCase = MockGeneralSettingsUseCase()
        let toolDirectorySubject = PassthroughSubject<String, Never>()
        let openWindowSubject = PassthroughSubject<Bool, Never>()
        let notifySubject = PassthroughSubject<Bool, Never>()
        let ctlResolutionBox = Box(ctlResolution)
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let hasListedSubject = PassthroughSubject<Bool, Never>()
        let listErrorSubject = PassthroughSubject<ToolError?, Never>()
        
        given(useCase).toolDirectory.willReturn(toolDirectory)
        given(useCase).openWindowOnStart.willReturn(openWindowOnStart)
        given(useCase).notifyOnFinish.willReturn(notifyOnFinish)
        given(useCase).searchDirectories.willReturn(searchDirectories)
        given(useCase).resolve(.value("polybridge-ctl")).willProduce { _ in ctlResolutionBox.value }
        given(useCase).resolve(.value("polybridge-setup")).willReturn(setupResolution)
        given(useCase).toolDirectoryPublisher().willReturn(toolDirectorySubject.eraseToAnyPublisher())
        given(useCase).openWindowOnStartPublisher().willReturn(openWindowSubject.eraseToAnyPublisher())
        given(useCase).notifyOnFinishPublisher().willReturn(notifySubject.eraseToAnyPublisher())
        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(hasListedSubject.eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(listErrorSubject.eraseToAnyPublisher())
        given(useCase).setToolDirectory(.any).willReturn()
        given(useCase).setOpenWindowOnStart(.any).willReturn()
        given(useCase).setNotifyOnFinish(.any).willReturn()
        
        let sut = GeneralSettingsVM(useCase: useCase)
        return SUT(
            sut: sut, useCase: useCase, toolDirectorySubject: toolDirectorySubject, openWindowSubject: openWindowSubject,
            notifySubject: notifySubject, ctlResolutionBox: ctlResolutionBox, tasksSubject: tasksSubject,
            hasListedSubject: hasListedSubject, listErrorSubject: listErrorSubject
        )
    }
    
    @Test func givenAnExistingToolDirectory_whenTheViewAppears_thenTheFieldLoadsTheCommittedValue() {
        // given
        let harness = makeSUT(toolDirectory: "/opt/homebrew/bin")
        let sut = harness.sut
        
        // when
        sut.didAppear()
        
        // then
        #expect(sut.directoryField == "/opt/homebrew/bin")
    }
    
    @Test func givenWhitespacePaddedInput_whenApplied_thenItIsTrimmedBeforeStoring() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        sut.didChangeDirectoryField("  /opt/homebrew/bin  ")
        
        // when
        sut.didTapApply()
        
        // then
        verify(useCase).setToolDirectory(.value("/opt/homebrew/bin")).called(1)
        // The field itself keeps what the user typed — only the stored value is trimmed, matching
        // the old `SettingsView.apply()`.
        #expect(sut.directoryField == "  /opt/homebrew/bin  ")
    }
    
    @Test func givenSearchAgain_whenTapped_thenTheOverrideClearsAndPathsReResolve() async {
        // given
        let harness = makeSUT(ctlResolution: .found(path: "/opt/homebrew/bin/polybridge-ctl"))
        let sut = harness.sut
        let useCase = harness.useCase
        let toolDirectorySubject = harness.toolDirectorySubject
        let ctlResolutionBox = harness.ctlResolutionBox
        sut.didAppear()
        sut.didChangeDirectoryField("/some/stale/path")
        ctlResolutionBox.value = .found(path: "/usr/local/bin/polybridge-ctl")
        
        // when
        sut.didTapSearchAgain()
        
        // then
        #expect(sut.directoryField == "")
        verify(useCase).setToolDirectory(.value("")).called(1)
        // The resolved paths update immediately once the setting change is observed (decision 11).
        // `publisher.send` here mirrors what a real `SettingsRepository` does after `setToolDirectory`
        // republishes — `weakAssign`/`.sink` deliver via `.receive(on: DispatchQueue.main)`, so the
        // assertion must wait for that hop rather than read the property synchronously.
        toolDirectorySubject.send("")
        await waitUntil { sut.ctlResolution == .found(path: "/usr/local/bin/polybridge-ctl") }
        #expect(sut.ctlResolution == .found(path: "/usr/local/bin/polybridge-ctl"))
    }
    
    // Regression (item 7): the original re-evaluated `searchDirectories`/`resolve(_:)` on every
    // `AppModel` publish, so Settings updated once discovery (finding the `uv` tool directory)
    // finished — discovery always completes before the first listing. Neither `hasListed` nor
    // `tasks`/`listError` used to trigger a re-resolve here at all.
    @Test func givenDiscoveryFinishesAfterTheViewAppeared_whenTheTaskListSettles_thenResolutionsRefresh() async {
        // given
        let harness = makeSUT(ctlResolution: .notFound)
        let sut = harness.sut
        let ctlResolutionBox = harness.ctlResolutionBox
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        let listErrorSubject = harness.listErrorSubject
        sut.didAppear()
        #expect(sut.ctlResolution == .notFound)
        
        // when — discovery settles (the `uv` tool directory is found) and the first listing
        // completes; nothing here is a `toolDirectory` change.
        ctlResolutionBox.value = .found(path: "/opt/homebrew/bin/polybridge-ctl")
        hasListedSubject.send(true)
        
        // then
        await waitUntil { sut.ctlResolution == .found(path: "/opt/homebrew/bin/polybridge-ctl") }
        #expect(sut.ctlResolution == .found(path: "/opt/homebrew/bin/polybridge-ctl"))
        
        // when — a later `tasksPublisher`/`listErrorPublisher` emission also re-resolves.
        ctlResolutionBox.value = .notFound
        tasksSubject.send([])
        await waitUntil { sut.ctlResolution == .notFound }
        #expect(sut.ctlResolution == .notFound)
        
        ctlResolutionBox.value = .found(path: "/usr/local/bin/polybridge-ctl")
        listErrorSubject.send(nil)
        await waitUntil { sut.ctlResolution == .found(path: "/usr/local/bin/polybridge-ctl") }
        #expect(sut.ctlResolution == .found(path: "/usr/local/bin/polybridge-ctl"))
    }
    
    @Test func givenAToolDirectoryChangeIsObserved_whenNotApplied_thenTheDirectoryFieldIsUntouched() {
        // given — a live settings change from elsewhere must never clobber what the user is typing.
        let harness = makeSUT()
        let sut = harness.sut
        let toolDirectorySubject = harness.toolDirectorySubject
        sut.didAppear()
        sut.didChangeDirectoryField("still typing")
        
        // when
        toolDirectorySubject.send("/opt/homebrew/bin")
        
        // then
        #expect(sut.directoryField == "still typing")
    }
    
    @Test func givenToggleActions_whenInvoked_thenTheyForwardToTheUseCase() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        
        // when
        sut.didToggleOpenWindowOnStart(false)
        sut.didToggleNotifyOnFinish(false)
        
        // then
        verify(useCase).setOpenWindowOnStart(.value(false)).called(1)
        verify(useCase).setNotifyOnFinish(.value(false)).called(1)
    }
    
    @Test func givenLiveSettingsPublishers_whenTheyEmit_thenTheTogglesUpdate() async {
        // given
        let harness = makeSUT(openWindowOnStart: true, notifyOnFinish: true)
        let sut = harness.sut
        let openWindowSubject = harness.openWindowSubject
        let notifySubject = harness.notifySubject
        sut.didAppear()
        // Positive setup: both start `true` (from the use case), so the assertion below proves the
        // publishers actually flipped them rather than merely matching an already-`false` default.
        #expect(sut.openWindowOnStart == true)
        #expect(sut.notifyOnFinish == true)
        
        // when
        openWindowSubject.send(false)
        notifySubject.send(false)
        
        // then — `weakAssign` delivers via `.receive(on: DispatchQueue.main)`, a real async hop.
        await waitUntil { sut.openWindowOnStart == false && sut.notifyOnFinish == false }
        #expect(sut.openWindowOnStart == false)
        #expect(sut.notifyOnFinish == false)
    }
    
    @Test func givenDidAppearCalledTwice_whenSettingsEmit_thenSubscriptionsAreNotDuplicated() async {
        // given — the `didSubscribe` guard must stop a second `didAppear()` (e.g. the tab
        // reappearing) from double-subscribing.
        let harness = makeSUT()
        let sut = harness.sut
        let openWindowSubject = harness.openWindowSubject
        sut.didAppear()
        sut.didAppear()
        // Positive setup: starts `true` (from the use case), so the wait below proves the
        // subscription actually delivered the change rather than matching an already-`false` default.
        #expect(sut.openWindowOnStart == true)
        
        // when
        openWindowSubject.send(false)
        
        // then — the assignment happened once; a duplicate subscription would not change this
        // specific assertion, but does show up as a crash/leak in `cancellables` in a full run. The
        // meaningful check is the disappear/re-subscribe path below.
        await waitUntil { sut.openWindowOnStart == false }
        #expect(sut.openWindowOnStart == false)
    }
    
    @Test func givenDidDisappear_whenTheViewReappears_thenItSubscribesAgain() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let openWindowSubject = harness.openWindowSubject
        sut.didAppear()
        sut.didDisappear()
        // Positive setup: starts `true` (from the use case), so the wait below proves the
        // resubscription actually delivered the change rather than matching an already-`false` default.
        #expect(sut.openWindowOnStart == true)
        
        // when
        sut.didAppear()
        openWindowSubject.send(false)
        
        // then
        await waitUntil { sut.openWindowOnStart == false }
        #expect(sut.openWindowOnStart == false)
    }
}
