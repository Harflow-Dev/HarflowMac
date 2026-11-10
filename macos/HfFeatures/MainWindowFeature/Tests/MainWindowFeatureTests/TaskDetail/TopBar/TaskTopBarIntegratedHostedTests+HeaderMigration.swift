import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - Standalone header migration

extension TaskTopBarIntegratedHostedTests {
    @Test(arguments: [TopBarChip.notices, .continuity], [1280.0, 1000.0])
    func givenAToolbarChipReveal_whenEscapeIsPressedTwice_thenFocusReturnsToTheChipAndThePaneCloses(
        chip: TopBarChip, width: Double
    ) async throws {
        // given — the sidebar leaves split and overlay detail widths respectively.
        let fixture = await Fixture(.init(width: width, notices: 1))
        defer { fixture.close() }
        let origin = try await fixture.headerMigrationChip(chip)
        #expect(!fixture.hasPane)

        // when — the actual toolbar chip reveals and focuses its Events group.
        #expect(M04ToolbarEvidence.press(origin.button))
        await fixture.waitForMigrationGroup(chip)

        // then
        #expect(fixture.hasPane)
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .events)
        #expect(fixture.store.expandedGroups(for: Fixture.conversation).contains(chip.group))
        #expect(fixture.groupValue(chip.header) == "Expanded")
        #expect(fixture.groupHeader(chip.header).flatMap(fixture.screenFrame(ofElement:)) != nil)
        #expect(fixture.focusedLabel?.hasPrefix(chip.header) == true)

        // when — first Escape returns focus while leaving the revealed pane open.
        try fixture.sendMigrationEscape()
        await fixture.waitForMigrationReturn(origin)

        // then
        #expect(fixture.focusReturn(to: origin.item, label: origin.label) != nil)
        #expect(fixture.hasPane)
        #expect(fixture.store.openChoice(for: Fixture.conversation) == .open)
        #expect(fixture.store.expandedGroups(for: Fixture.conversation).contains(chip.group))

        // when — the next Escape closes the reveal, even at split width.
        try fixture.sendMigrationEscape()
        await waitUntil(timeout: 8) { fixture.keepActive(); fixture.pump(); return !fixture.hasPane }
        await fixture.waitForMigrationReturn(origin)

        // then
        #expect(!fixture.hasPane)
        #expect(fixture.store.openChoice(for: Fixture.conversation) == .closed)
        #expect(fixture.focusReturn(to: origin.item, label: origin.label) != nil)
    }

    @Test func givenTwoToolbarChipsPressedInQuickSuccession_whenTheSecondIsNewest_thenItsGroupKeepsFocus() async throws {
        // given
        let fixture = await Fixture(.init(width: 1280, notices: 1))
        defer { fixture.close() }
        let notices = try await fixture.headerMigrationChip(.notices)
        let continuity = try await fixture.headerMigrationChip(.continuity)

        // when — no render or pump between the two actual toolbar presses.
        #expect(M04ToolbarEvidence.press(notices.button))
        #expect(M04ToolbarEvidence.press(continuity.button))
        await fixture.waitForMigrationGroup(.continuity)

        // then
        #expect(fixture.focusedLabel?.hasPrefix("Continuity") == true)
        #expect(fixture.store.expandedGroups(for: Fixture.conversation) == [.notices, .continuity])
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .events)
        fixture.pump(times: 30) // Nothing-happened check: an earlier request must never land later.
        #expect(fixture.focusedLabel?.hasPrefix("Continuity") == true)
    }

    @Test func givenAToolbarChipRevealThenAClose_whenTheCloseLandsFirst_thenNoFocusEntersTheAbsentGroup() async throws {
        // given
        let fixture = await Fixture(.init(width: 1280, notices: 1))
        defer { fixture.close() }
        let origin = try await fixture.headerMigrationChip(.notices)

        // when — retain the existing close-before-render race through persisted pane state.
        #expect(M04ToolbarEvidence.press(origin.button))
        fixture.store.setOpenChoice(.closed, for: Fixture.conversation)
        await waitUntil(timeout: 8) { fixture.pump(); return !fixture.hasPane }
        fixture.pump(times: 30)

        // then
        #expect(!fixture.hasPane)
        #expect(fixture.focusedLabel?.hasPrefix("Notices") != true)
        #expect(fixture.store.openChoice(for: Fixture.conversation) == .closed)
    }

    @Test func givenAToolbarChipRevealThenATabSwitch_whenTheSwitchLandsFirst_thenNoFocusEntersTheOldGroup() async throws {
        // given
        let fixture = await Fixture(.init(width: 1280, notices: 1))
        defer { fixture.close() }
        let origin = try await fixture.headerMigrationChip(.notices)

        // when — retain the existing tab-before-render race through persisted pane state.
        #expect(M04ToolbarEvidence.press(origin.button))
        fixture.store.setSelectedTab(.artifacts, for: Fixture.conversation)
        await waitUntil(timeout: 8) { fixture.pump(); return fixture.hasPane && fixture.groupHeader("Task") == nil }
        fixture.pump(times: 30)

        // then
        #expect(fixture.hasPane)
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .artifacts)
        #expect(fixture.groupHeader("Task") == nil)
        #expect(fixture.focusedLabel?.hasPrefix("Notices") != true)
    }

    @Test func givenAnOpenPane_whenAToolbarRevealIsImmediatelyFollowedByTheArtifactsButton_thenTheVisibleTabFollowsThePerson() async throws {
        // given — capture the rendered Artifacts control before the reveal can schedule a render.
        let fixture = await Fixture(.init(width: 1280, notices: 1, openPane: true))
        defer { fixture.close() }
        let origin = try await fixture.headerMigrationChip(.notices)
        let artifacts = try #require(fixture.contentElement(labelled: "Artifacts"))

        // when — actual controls, with no pump or yield between presses.
        #expect(M04ToolbarEvidence.press(origin.button))
        #expect(M04ToolbarEvidence.press(artifacts))
        await fixture.waitForMigrationArtifacts()
        fixture.pump(times: 30) // A delayed reveal must not replace the person's tab or focus.

        // then — stored selection alone is insufficient evidence of the displayed body.
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .artifacts)
        #expect(fixture.contentText("Registered artifacts") != nil)
        #expect(fixture.groupHeader("Task") == nil)
        #expect(fixture.focusedLabel?.hasPrefix("Notices") != true)

        // when — ordinary tab navigation after the reveal has been superseded.
        let events = try #require(fixture.contentElement(labelled: "Events"))
        #expect(M04ToolbarEvidence.press(events))
        await waitUntil(timeout: 8) {
            fixture.keepActive()
            fixture.pump()
            return fixture.groupHeader("Task") != nil && fixture.contentText("Registered artifacts") == nil
        }

        // then
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .events)
        #expect(fixture.groupHeader("Task") != nil)
        #expect(fixture.contentText("Registered artifacts") == nil)

        // when — another ordinary switch must update the body without a fresh reveal.
        let artifactsAgain = try #require(fixture.contentElement(labelled: "Artifacts"))
        #expect(M04ToolbarEvidence.press(artifactsAgain))
        await fixture.waitForMigrationArtifacts()

        // then
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .artifacts)
        #expect(fixture.contentText("Registered artifacts") != nil)
        #expect(fixture.groupHeader("Task") == nil)
    }

    @Test func givenAToolbarNoticeChipRevealAtSplitWidth_whenRepeatedManyTimes_thenEveryRunClosesOnTheSecondEscape() async throws {
        for iteration in 1 ... 8 {
            // given
            let fixture = await Fixture(.init(width: 1280, notices: 1))
            defer { fixture.close() }
            let origin = try await fixture.headerMigrationChip(.notices)
            #expect(M04ToolbarEvidence.press(origin.button))
            await fixture.waitForMigrationGroup(.notices)
            #expect(fixture.focusedLabel?.hasPrefix("Notices") == true, "iteration \(iteration)")

            // when
            try fixture.sendMigrationEscape()
            await fixture.waitForMigrationReturn(origin)
            #expect(fixture.focusReturn(to: origin.item, label: origin.label) != nil, "iteration \(iteration)")
            #expect(fixture.hasPane, "iteration \(iteration)")
            #expect(fixture.store.openChoice(for: Fixture.conversation) == .open, "iteration \(iteration)")
            try fixture.sendMigrationEscape()
            await waitUntil(timeout: 8) { fixture.keepActive(); fixture.pump(); return !fixture.hasPane }

            // then
            #expect(!fixture.hasPane, "iteration \(iteration): focus \(String(describing: fixture.focusedLabel))")
            #expect(fixture.store.openChoice(for: Fixture.conversation) == .closed, "iteration \(iteration)")
        }
    }
}

// MARK: - Real toolbar interaction helpers

private extension TopBarIntegratedFixture {
    struct MigrationOrigin {
        let item: NSToolbarItem
        let button: NSObject
        let label: String
    }

    func headerMigrationChip(_ chip: TopBarChip) async throws -> MigrationOrigin {
        keepActive()
        let content = try #require(content)
        let label = chip.label(for: content)
        await waitUntil(timeout: 8) {
            self.keepActive()
            self.pump()
            return self.item(chip.identifier).flatMap { self.element(labelled: label, in: $0) } != nil
        }
        let item = try #require(self.item(chip.identifier))
        let button = try #require(element(labelled: label, in: item))
        #expect(isOnScreen(item))
        return MigrationOrigin(item: item, button: button, label: label)
    }

    func waitForMigrationGroup(_ chip: TopBarChip) async {
        await waitUntil(timeout: 8) {
            self.keepActive()
            self.pump()
            self.publish()
            return self.groupValue(chip.header) == "Expanded" && self.focusedLabel?.hasPrefix(chip.header) == true
        }
    }

    func waitForMigrationReturn(_ origin: MigrationOrigin) async {
        await waitUntil(timeout: 8) {
            self.keepActive()
            self.pump()
            return self.focusReturn(to: origin.item, label: origin.label) != nil
        }
    }

    func waitForMigrationArtifacts() async {
        await waitUntil(timeout: 8) {
            self.keepActive()
            self.pump()
            return self.contentText("Registered artifacts") != nil && self.groupHeader("Task") == nil
        }
    }

    func sendMigrationEscape() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ))
        NSApp.sendEvent(event)
    }
}
