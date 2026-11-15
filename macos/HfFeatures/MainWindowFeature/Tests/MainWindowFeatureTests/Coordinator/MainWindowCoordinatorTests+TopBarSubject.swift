import Foundation
import HfCommon
import HfCommonTestMock
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

extension MainWindowCoordinatorTests {
    @Test func givenGroupAndTaskSelections_whenAskingForTheTopBarSubject_thenItFollowsTheSelection() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())

        // when / then
        sut.selection = .group("release")
        #expect(sut.shownTopBarSubject() == .group("release"))
        #expect(sut.topBar.shownSubject == .group("release"))
        sut.selection = .task("abc123")
        #expect(sut.shownTopBarSubject() == .task("abc123"))
        #expect(sut.topBar.shownConversation == "abc123")
        sut.selection = .statistics
        #expect(sut.shownTopBarSubject() == nil)
        #expect(sut.topBar.shownSubject == nil)
    }

    @Test func givenAGroupWriter_whenItActivatesThroughTheCoordinator_thenItIsAcceptedOnlyForTheSelectedGroup() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        let writer = TopBarFixtures.Writer()
        let tag = TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .group("release"))
        let routing: any ParallelRouting = sut
        let content = GroupTopBarContent(title: "release", badge: nil, meta: nil)

        // when / then — another selection refuses it
        sut.selection = .group("other")
        routing.publishTopBar(content, tag: tag)
        routing.activateTopBar(tag: tag)
        #expect(sut.topBar.shownGroup == nil)

        // the group's own selection accepts a fresh write
        sut.selection = .group("release")
        routing.publishTopBar(content, tag: tag)
        routing.activateTopBar(tag: tag)
        #expect(sut.topBar.shownGroup?.title == "release")
        routing.deactivateTopBar(tag: tag)
        #expect(sut.topBar.shownGroup == nil)
        routing.clearTopBar(tag: tag)
    }

    @Test func givenThePendingLaunchesSelection_whenAskingForTheTopBarSubject_thenItIsThePage() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())

        // when
        sut.selection = .pendingLaunches

        // then
        #expect(sut.shownTopBarSubject() == .pendingLaunches)
        #expect(sut.topBar.shownSubject == .pendingLaunches)
        #expect(sut.topBar.shownConversation == nil)
    }

    @Test func givenAPageWriter_whenItActivatesThroughTheCoordinator_thenItIsAcceptedOnlyOnThePendingLaunchesPage() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        let writer = TopBarFixtures.Writer()
        let tag = TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .pendingLaunches)
        let routing: any PendingLaunchesTopBarRouting = sut
        let content = PageTopBarContent.pendingLaunches(title: "Review checks")

        // when / then: another selection refuses it
        sut.selection = .statistics
        routing.publishTopBar(content, tag: tag)
        routing.activateTopBar(tag: tag)
        #expect(sut.topBar.shownPage == nil)

        // the page's own selection accepts a fresh write
        sut.selection = .pendingLaunches
        routing.publishTopBar(content, tag: tag)
        routing.activateTopBar(tag: tag)
        #expect(sut.topBar.shownPage?.title == "Review checks")
        #expect(sut.topBar.shown == nil)
        #expect(sut.topBar.shownGroup == nil)

        // leaving the page hides it; deactivation and clear are safe afterwards
        sut.selection = .statistics
        #expect(sut.topBar.shownPage == nil)
        routing.deactivateTopBar(tag: tag)
        routing.clearTopBar(tag: tag)
    }

    @Test func givenAPageWriter_whenItDeactivatesAndClears_thenTheBarIsEmpty() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        let writer = TopBarFixtures.Writer()
        let tag = TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .pendingLaunches)
        let routing: any PendingLaunchesTopBarRouting = sut
        sut.selection = .pendingLaunches
        routing.publishTopBar(.pendingLaunchesInventory, tag: tag)
        routing.activateTopBar(tag: tag)
        #expect(sut.topBar.shownPage == .pendingLaunchesInventory)

        // when
        routing.deactivateTopBar(tag: tag)
        routing.clearTopBar(tag: tag)

        // then
        #expect(sut.topBar.shownPage == nil)
    }
}
