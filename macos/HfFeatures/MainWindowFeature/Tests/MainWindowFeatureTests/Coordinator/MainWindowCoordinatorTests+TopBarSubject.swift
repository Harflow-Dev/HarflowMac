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
}
